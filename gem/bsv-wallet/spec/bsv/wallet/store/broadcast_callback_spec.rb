# frozen_string_literal: true

require_relative 'shared_context'

require 'rack/test'

RSpec.describe BSV::Wallet::Store::BroadcastCallback, :store do
  include Rack::Test::Methods

  let(:broadcast_queue) { BSV::Wallet::Store::BroadcastQueue.new }
  let(:app) { described_class.new(broadcast_queue: broadcast_queue) }

  let(:action) do
    BSV::Wallet::Store::Models::Action.create(
      outgoing: true,
      description: 'test action',
      nlocktime: 0,
      wtxid: SecureRandom.random_bytes(32),
      raw_tx: SecureRandom.random_bytes(100)
    )
  end

  let(:txid_hex) { action.dtxid }

  describe 'POST /' do
    it 'parses ARC TransactionStatus JSON and delegates to handle_event' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id)

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
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id)
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
