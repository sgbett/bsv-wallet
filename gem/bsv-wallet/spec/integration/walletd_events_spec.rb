# frozen_string_literal: true

# Integration smoke spec for walletd events end-to-end.
#
# Boots a Daemon with stubbed Store + Services against a StringIO-backed
# BSV.logger, exercises one broadcast cycle (success path) and one proof
# cycle (acquired path) via OMQ inproc sockets, and asserts the canonical
# event sequence appears in the log output.

require 'spec_helper'
require 'logger'
require 'stringio'
require 'bsv/wallet/daemon'

RSpec.describe 'walletd events end-to-end' do # rubocop:disable RSpec/DescribeClass
  let(:log_output) { StringIO.new }

  let(:wtxid) { SecureRandom.random_bytes(32) }
  let(:dtxid) { wtxid.reverse.unpack1('H*') }
  # Real signed P2PKH transaction (1 input, 1 output) so #252's daemon-side
  # EF reconstruction (Engine::Broadcast#hydrated_transaction_for) can parse
  # action[:raw_tx] and walk its inputs. The resolved_inputs let below
  # matches this tx's single input so #attach! has source data to wire in.
  let(:raw_tx) do
    ['01000000016ce7229f014164e254aad172b1f8b40d496942ad7e323b47e0424c2b2e2e3772010000006a47' \
     '30440220463fcf8f57a61c4f8ede208773db8732bf3a0757d929a8cbbe29bf4905fe5ef6022005d74398fa' \
     'f5b24912821836171af44f55f89858f3edf92863cde4823da11d4641210362f5fb9274834bb0cd0376a8d5' \
     'd02bdbf459a37a62c5baef3fb06d1159b55597ffffffff01f0991600000000001976a9141f36a49fcf6ada' \
     '1f74f82377b33b17b68f7a016188acd3740e00'].pack('H*')
  end
  let(:resolved_inputs) do
    [{ source_satoshis: 1_500_000, source_locking_script: ["76a914#{'a' * 40}88ac"].pack('H*') }]
  end
  let(:merkle_path_binary) { "\x01\x02\x03".b }

  let(:store) { double('Store') }

  # Services normalizes successful responses to symbol + snake_case keys.
  let(:broadcast_response) do
    BSV::Network::ProtocolResponse.new(
      nil,
      data: {
        txid: dtxid,
        tx_status: 'SEEN_ON_NETWORK',
        status: 200,
        block_hash: nil,
        block_height: nil,
        merkle_path: nil,
        extra_info: nil,
        competing_txs: nil
      },
      http_success: true
    )
  end

  let(:proof_response) do
    double('Response',
           http_success?: true,
           data: {
             merkle_path: merkle_path_binary,
             block_height: 850_000,
             block_hash: SecureRandom.hex(32)
           })
  end

  let(:broadcaster) { double('Broadcaster') }

  around do |example|
    original_logger = BSV.logger
    BSV.logger = Logger.new(log_output, level: Logger::INFO)
    # OMQ inproc registry reset is handled globally in spec_helper.
    example.run
  ensure
    BSV.logger = original_logger
  end

  before do
    # --- Store stubs ---

    # Submission discovery: return one action on first call, empty thereafter.
    # The action has no broadcasts row yet (broadcast_status returns nil),
    # so Engine::Broadcast#process takes the submit branch end-to-end.
    submission_call_count = 0
    allow(store).to receive(:pending_submissions) do |**_kwargs|
      submission_call_count += 1
      submission_call_count == 1 ? [{ action_id: 1 }] : []
    end

    # Proof discovery: return one action on first call, empty thereafter.
    proof_call_count = 0
    allow(store).to receive(:pending_proofs) do |**_kwargs|
      proof_call_count += 1
      proof_call_count == 1 ? [{ id: 2, wtxid: wtxid }] : []
    end

    # Action lookup -- broadcast uses action_id 1, proof uses action_id 2.
    allow(store).to receive(:find_action) do |id:|
      case id
      when 1 then { id: 1, raw_tx: raw_tx, wtxid: wtxid }
      when 2 then { id: 2, raw_tx: raw_tx, wtxid: wtxid }
      end
    end

    # Resolution discovery is dormant (pending_resolutions: []) so all
    # broadcast lifecycle events in this smoke come from the submission
    # path. A dedicated resolution-path smoke is a separate concern.
    allow(store).to receive_messages(
      pending_resolutions: [],
      # Reaper discovery loop runs alongside broadcast/proof; keep it dormant.
      stale_action_ids: [],
      record_broadcast_result: nil,
      broadcast_status: nil,
      mark_broadcast_attempted: nil,
      save_proof: 99,
      link_proof: nil,
      promote_action_outputs: []
    )
    # EF reconstruction (#252) at submit time calls into the Store to hydrate
    # per-input source data.
    allow(store).to receive(:resolve_inputs_for_signing).with(action_id: 1).and_return(resolved_inputs)

    # --- Network stubs ---
    allow(broadcaster).to receive(:get_tx_status).with(wtxid: wtxid, dtxid: dtxid).and_return(proof_response)
    allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Tx), wtxid: wtxid).and_return(broadcast_response)
  end

  it 'emits the canonical event sequence across one broadcast and one proof cycle' do
    daemon = BSV::Wallet::Daemon.new(store: store, broadcaster: broadcaster,
                                     wallet: 'alice', network: :mainnet)

    Async do |task|
      # Start the daemon (non-blocking -- spawns child fibers).
      daemon.run!

      # Wait for both engines to finish processing. The scheduler's first
      # cycle fires immediately, but OMQ subscriber bind and engine process
      # roundtrip timing is non-deterministic. Poll the log for the two
      # task.succeeded events rather than using a fixed sleep.
      deadline = Time.now + 5
      loop do
        break if log_output.string.scan('task.succeeded').size >= 2
        raise 'Timed out waiting for engine events' if Time.now > deadline

        sleep 0.05
      end
    ensure
      # Stop the daemon outside the main flow. daemon.stop! emits
      # daemon.stopped synchronously before killing the reactor task.
      daemon.stop!
      task.stop
    end

    log = log_output.string

    # Daemon lifecycle
    expect(log).to include('[event] daemon.started wallet=alice network=mainnet')
    expect(log).to include('[event] daemon.stopped reason=signal')

    # Broadcast cycle: discovered -> enqueued -> dispatched -> succeeded
    expect(log).to include('[event] task.discovered task=broadcast_submission count=1')
    expect(log).to include('[event] task.enqueued task=broadcast_submission id=1')
    expect(log).to include('[event] task.dispatched task=broadcast_submission id=1')
    expect(log).to include('[event] task.succeeded task=broadcast_submission id=1')

    # Proof cycle: discovered -> enqueued -> dispatched -> succeeded
    expect(log).to include('[event] task.discovered task=proof_acquisition count=1')
    expect(log).to include('[event] task.enqueued task=proof_acquisition id=2')
    expect(log).to include('[event] task.dispatched task=proof_acquisition id=2')
    expect(log).to include('[event] task.succeeded task=proof_acquisition id=2')

    # Verify task.succeeded appears at least twice (once per engine)
    succeeded_lines = log.lines.select { |l| l.include?('[event] task.succeeded') }
    expect(succeeded_lines.size).to be >= 2
  end
end
