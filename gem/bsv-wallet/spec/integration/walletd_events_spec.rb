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
  let(:raw_tx) { "\x01\x00".b }
  let(:merkle_path_binary) { "\x01\x02\x03".b }

  let(:store) { double('Store') }

  let(:broadcast_response) do
    BSV::Network::ProtocolResponse.new(
      nil,
      data: {
        'txid' => dtxid,
        'txStatus' => 'SEEN_ON_NETWORK',
        'status' => 200,
        'blockHash' => nil,
        'blockHeight' => nil,
        'merklePath' => nil,
        'extraInfo' => nil,
        'competingTxs' => nil
      },
      http_success: true
    )
  end

  let(:proof_response) do
    double('Response',
           http_success?: true,
           data: {
             'merklePath' => merkle_path_binary,
             'blockHeight' => 850_000,
             'blockHash' => SecureRandom.hex(32)
           })
  end

  let(:services) { double('Services') }

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

    # Broadcast discovery: return one action on first call, empty thereafter.
    broadcast_call_count = 0
    allow(store).to receive(:pending_broadcasts) do |**_kwargs|
      broadcast_call_count += 1
      broadcast_call_count == 1 ? [{ action_id: 1 }] : []
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

    # Broadcast result recording.
    allow(store).to receive(:record_broadcast_result)
    allow(store).to receive(:broadcast_status)

    # Proof result recording.
    allow(store).to receive(:save_proof).and_return(99)
    allow(store).to receive(:link_proof)

    # --- Services stubs ---
    allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(broadcast_response)
    allow(services).to receive(:call).with(:get_tx_status, txid: dtxid).and_return(proof_response)
  end

  it 'emits the canonical event sequence across one broadcast and one proof cycle' do
    daemon = BSV::Wallet::Daemon.new(store: store, services: services,
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
    expect(log).to include('[event] task.discovered task=broadcast_push count=1')
    expect(log).to include('[event] task.enqueued task=broadcast_push id=1')
    expect(log).to include('[event] task.dispatched task=broadcast_push id=1')
    expect(log).to include('[event] task.succeeded task=broadcast_push id=1')

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
