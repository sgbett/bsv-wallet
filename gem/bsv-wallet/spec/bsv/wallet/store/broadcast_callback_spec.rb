# frozen_string_literal: true

require_relative 'shared_context'

require 'rack/test'

RSpec.describe BSV::Wallet::Store::BroadcastCallback, :store do
  include Rack::Test::Methods

  let(:app) { described_class.new(store: store) }

  let(:action) do
    BSV::Wallet::Store::Models::Action.create(
      description: 'test action',
      nlocktime: 0,
      wtxid: SecureRandom.random_bytes(32),
      raw_tx: SecureRandom.random_bytes(100)
    )
  end

  let(:txid_hex) { action.dtxid }

  describe 'POST /' do
    it 'parses ARC TransactionStatus JSON and delegates to handle_event' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')

      payload = {
        txid: txid_hex,
        txStatus: 'SEEN_ON_NETWORK',
        status: 200,
        blockHash: nil,
        blockHeight: nil,
        merklePath: nil,
        extraInfo: nil,
        competingTxs: nil
      }.to_json

      post '/', payload, 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)
      expect(broadcast.tx_status).to eq('SEEN_ON_NETWORK')
    end

    it 'hex-decodes binary fields' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')
      block_hash = SecureRandom.random_bytes(32)

      payload = {
        txid: txid_hex,
        txStatus: 'MINED',
        status: 200,
        blockHash: block_hash.unpack1('H*'),
        blockHeight: 800_000,
        merklePath: nil,
        extraInfo: nil,
        competingTxs: nil
      }.to_json

      post '/', payload, 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)
      expect(broadcast.block_hash).to eq(block_hash)
      expect(broadcast.block_hash.encoding).to eq(Encoding::BINARY)
    end

    it 'cascade-unwinds via reject_action on a definitive rejection' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')

      payload = {
        txid: txid_hex,
        txStatus: 'REJECTED',
        status: 200,
        blockHash: nil, blockHeight: nil,
        merklePath: nil, extraInfo: nil, competingTxs: nil
      }.to_json

      post '/', payload, 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)

      # reject_action ran: the action (and its cascading broadcast row) is
      # gone, rather than a stranded REJECTED tx_status the resolution loop
      # would never rediscover.
      expect(BSV::Wallet::Store::Models::Action[action.id]).to be_nil
      expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)).to be_nil
    end

    it 'ACKs (200) without bumping retry when the cascade hits an accepted descendant' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')
      allow(store).to receive(:reject_action)
        .and_raise(BSV::Wallet::CannotRejectAcceptedActionError.new(action.id, 'MINED'))
      allow(store).to receive(:increment_broadcast_retry)

      payload = {
        txid: txid_hex,
        txStatus: 'REJECTED',
        status: 200,
        blockHash: nil, blockHeight: nil,
        merklePath: nil, extraInfo: nil, competingTxs: nil
      }.to_json

      post '/', payload, 'CONTENT_TYPE' => 'application/json'

      # Accepted-divergence is not transient -- ACK so ARC stops re-delivering,
      # but do NOT bump retry_count (operator investigation, not a retry).
      expect(last_response.status).to eq(200)
      expect(store).not_to have_received(:increment_broadcast_retry)
    end

    it 'returns 400 for invalid JSON' do
      post '/', 'not json', 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(400)
    end

    it 'returns 200 for unknown txid (graceful ignore)' do
      payload = {
        txid: SecureRandom.random_bytes(32).unpack1('H*'),
        txStatus: 'MINED', status: 200,
        blockHash: nil, blockHeight: nil,
        merklePath: nil, extraInfo: nil, competingTxs: nil
      }.to_json

      post '/', payload, 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(200)
    end
  end
end
