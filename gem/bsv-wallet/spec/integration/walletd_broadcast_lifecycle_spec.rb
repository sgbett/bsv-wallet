# frozen_string_literal: true

# Integration spec for #270 — broadcast-submission lifecycle against a
# real Postgres store with a stubbed broadcaster, exercising the full
# +Engine::Broadcast#process+ decision surface.
#
# Each scenario stages a delayed-broadcast action + +broadcasts+ row,
# stubs the broadcaster with a fixed response shape, drives one
# +process+ cycle, then asserts the resulting DB state and emitted
# task event. The categorisation predicates
# (+terminal_failure?+ / +categorize_reason+) are now the single
# decision surface after #271; covering every response shape here is
# what locks the inline path's behaviour as well, since both routes
# converge on the same submit method.
#
# Shapes covered:
#   - 202 + SEEN_ON_NETWORK     (accepted)
#   - 400 {error, reason}       (Arcade synchronous-rejection 4xx) #270
#   - 400 {txStatus: REJECTED}  (status-poll-shape rejection)
#   - 503                       (backpressure / retry)
#   - 200 with no recognised txStatus (malformed-but-not-terminal)
#
# Postgres-only — relies on the action cascade FKs that translate to
# different SQL on SQLite. The cascade behaviour is the load-bearing
# assertion for terminal rejections.

require 'spec_helper'
require 'net/http'
require 'securerandom'
require 'sequel'
require 'bsv-wallet'

RSpec.describe 'Engine::Broadcast#process lifecycle (#270)', :postgres do # rubocop:disable RSpec/DescribeClass
  let(:database_url) { ENV.fetch('DATABASE_URL') }
  let(:store) { BSV::Wallet::Store.connect(database_url).tap(&:migrate!) }

  # Real signed P2PKH transaction — parseable by Transaction::Tx.from_binary
  # so +Engine::Broadcast#hydrated_transaction_for+ can reconstruct it
  # for the broadcaster call. The exact bytes don't matter for the
  # rejection paths (broadcaster.broadcast is stubbed) but the parse
  # has to succeed before broadcaster is reached.
  let(:raw_tx) do
    ['01000000016ce7229f014164e254aad172b1f8b40d496942ad7e323b47e0424c2b2e2e3772010000006a47' \
     '30440220463fcf8f57a61c4f8ede208773db8732bf3a0757d929a8cbbe29bf4905fe5ef6022005d74398fa' \
     'f5b24912821836171af44f55f89858f3edf92863cde4823da11d4641210362f5fb9274834bb0cd0376a8d5' \
     'd02bdbf459a37a62c5baef3fb06d1159b55597ffffffff01f0991600000000001976a9141f36a49fcf6ada' \
     '1f74f82377b33b17b68f7a016188acd3740e00'].pack('H*')
  end
  let(:wtxid)  { BSV::Transaction::Tx.from_binary(raw_tx).wtxid }
  let(:dtxid)  { wtxid.reverse.unpack1('H*') }

  # Provider double — each context overrides +broadcast_response+ to
  # exercise a different decision branch.
  let(:provider_name) { 'StubProvider' }
  let(:provider) do
    p = instance_double(BSV::Network::Provider,
                        name: provider_name,
                        commands: Set.new(%i[broadcast]),
                        rate_limit: nil)
    allow(p).to receive(:call).with(:broadcast, any_args).and_return(broadcast_response)
    p
  end
  let(:broadcaster) { BSV::Network::Broadcaster.new(providers: [provider], store: store) }
  let(:broadcast) { BSV::Wallet::Engine::Broadcast.new(store: store, broadcaster: broadcaster) }

  let(:emitted_events) { [] }
  # Stage one delayed-broadcast action + +broadcasts+ row + a
  # resolve_inputs_for_signing entry that matches the +raw_tx+ above
  # (single input). Returns the new +action_id+.
  let(:action_id) do
    id = store.db[:actions].insert(
      description: 'lifecycle test',
      broadcast_intent: 'delayed',
      wtxid: Sequel.blob(wtxid),
      raw_tx: Sequel.blob(raw_tx)
    )
    store.db[:broadcasts].insert(action_id: id, intent: 'delayed')
    allow(store).to receive(:resolve_inputs_for_signing).with(action_id: id).and_return(
      [{ source_satoshis: 1_500_000, source_locking_script: ["76a914#{'a' * 40}88ac"].pack('H*') }]
    )
    id
  end

  before do
    skip 'Postgres-only spec' unless ENV['DATABASE_URL'].to_s.start_with?('postgres')

    store.db.tables.each do |table|
      next if table == :schema_info

      store.db[table].truncate(cascade: true)
    end

    allow(BSV::Wallet).to receive(:emit) { |name, **payload| emitted_events << { name: name, **payload } }
  end

  context 'with a 2xx SEEN_ON_NETWORK response (accepted)' do
    let(:broadcast_response) do
      BSV::Network::ProtocolResponse.new(
        nil,
        data: { 'txid' => dtxid, 'txStatus' => 'SEEN_ON_NETWORK', 'status' => 200 },
        http_success: true
      )
    end

    it 'records the broadcast result and leaves the action alive' do
      broadcast.process(action_id)

      action = store.db[:actions].where(id: action_id).first
      expect(action).not_to be_nil

      row = store.db[:broadcasts].where(action_id: action_id).first
      expect(row[:tx_status]).to eq('SEEN_ON_NETWORK')
      expect(row[:provider]).to eq(provider_name)

      succeeded = emitted_events.find { |e| e[:name] == 'task.succeeded' }
      expect(succeeded).to include(task: 'broadcast_submission', id: action_id, outcome: :accepted)
    end
  end

  context 'with a 400 {error, reason} response (Arcade synchronous rejection)' do
    let(:broadcast_response) do
      BSV::Network::ProtocolResponse.new(
        nil,
        http_success: false,
        data: { 'error' => 'invalid input', 'reason' => "'PreviousTx' not supplied" }
      )
    end

    it 'cascades the action and emits task.aborted with arc_reason but no arc_status' do
      broadcast.process(action_id)

      expect(store.db[:actions].where(id: action_id).first).to be_nil

      aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
      expect(aborted).to include(
        task: 'broadcast_submission', id: action_id,
        reason: :policy_violation,
        arc_reason: "'PreviousTx' not supplied"
      )
      expect(aborted).not_to have_key(:arc_status)
    end
  end

  context 'with a 4xx {txStatus: REJECTED} response (status-poll-shape rejection)' do
    let(:broadcast_response) do
      BSV::Network::ProtocolResponse.new(
        nil,
        http_success: false,
        data: { 'txid' => dtxid, 'txStatus' => 'REJECTED', 'extraInfo' => 'policy: too-low-fee' }
      )
    end

    it 'cascades the action and emits task.aborted with arc_status but no arc_reason' do
      broadcast.process(action_id)

      expect(store.db[:actions].where(id: action_id).first).to be_nil

      aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
      expect(aborted).to include(
        task: 'broadcast_submission', id: action_id,
        reason: :policy_violation,
        arc_status: 'REJECTED'
      )
      expect(aborted).not_to have_key(:arc_reason)
    end
  end

  context 'with a 503 backpressure response (transient)' do
    let(:http_response) { instance_double(Net::HTTPServiceUnavailable, code: '503') }
    let(:broadcast_response) do
      # Backpressure detection runs against the underlying Net::HTTPResponse
      # class (+retryable?+ on +ProtocolResponse+), so a real-shaped double
      # is required — kwargs alone don't reach the predicate.
      allow(http_response).to receive(:is_a?).and_return(false)
      allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(http_response).to receive(:is_a?).with(Net::HTTPTooManyRequests).and_return(false)
      allow(http_response).to receive(:is_a?).with(Net::HTTPServerError).and_return(true)
      BSV::Network::ProtocolResponse.new(http_response, http_success: false, error_message: 'Arcade backpressure')
    end

    it 'leaves the action alive and emits task.failed with reason=:backpressure' do
      broadcast.process(action_id)

      expect(store.db[:actions].where(id: action_id).first).not_to be_nil

      failed = emitted_events.find { |e| e[:name] == 'task.failed' }
      expect(failed).to include(task: 'broadcast_submission', id: action_id, reason: :backpressure)
    end
  end

  context 'with a 4xx malformed body (no recognised status shape)' do
    let(:broadcast_response) do
      BSV::Network::ProtocolResponse.new(
        nil,
        http_success: false,
        data: { 'foo' => 'bar' } # neither {error, reason} nor {txStatus, extraInfo}
      )
    end

    it 'leaves the action alive and emits task.failed with reason=:unknown' do
      broadcast.process(action_id)

      expect(store.db[:actions].where(id: action_id).first).not_to be_nil

      failed = emitted_events.find { |e| e[:name] == 'task.failed' }
      expect(failed).to include(task: 'broadcast_submission', id: action_id, reason: :unknown)
    end
  end
end
