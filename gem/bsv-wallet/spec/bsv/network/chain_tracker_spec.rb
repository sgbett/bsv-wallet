# frozen_string_literal: true

require 'sequel'
require 'net/http'

RSpec.describe BSV::Network::ChainTracker do
  # --- Test helpers ---

  def success(data)
    BSV::Network::ProtocolResponse.new(nil, data: data, http_success: true)
  end

  def error(message = 'network error')
    http_resp = instance_double(Net::HTTPResponse).tap do |r|
      allow(r).to receive(:is_a?).and_return(false)
      allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(r).to receive(:is_a?).with(Net::HTTPNotFound).and_return(false)
      allow(r).to receive(:is_a?).with(Net::HTTPTooManyRequests).and_return(false)
      allow(r).to receive(:is_a?).with(Net::HTTPServerError).and_return(true)
    end
    BSV::Network::ProtocolResponse.new(http_resp, http_success: false, error_message: message)
  end

  # Hex merkle root and its binary equivalent
  let(:merkle_root_hex) { 'a' * 64 }
  let(:merkle_root_bin) { [merkle_root_hex].pack('H*') }
  let(:wrong_root_hex) { 'b' * 64 }
  let(:block_hash_hex) { 'c' * 64 }
  let(:height) { 800_000 }

  let(:services) { instance_double(BSV::Network::Services, call: nil) }

  # Use plain doubles — insert_conflict is a Postgres extension method not
  # present on Sequel::Dataset, so instance_double would reject it.
  let(:blocks_dataset) { double('blocks_dataset') }
  let(:conflict_dataset) { double('conflict_dataset') }
  let(:where_dataset) { double('where_dataset') }
  let(:db) do
    dbl = instance_double(Sequel::Database)
    allow(dbl).to receive(:[]).with(:blocks).and_return(blocks_dataset)
    dbl
  end

  let(:tracker) { described_class.new(db: db, services: services) }

  # Shared stubs for the persist_block write path
  before do
    allow(blocks_dataset).to receive(:insert_conflict).with(target: :height).and_return(conflict_dataset)
    allow(conflict_dataset).to receive(:insert)
  end

  describe '#valid_root_for_height?' do
    context 'when the block exists in the database' do
      before do
        allow(blocks_dataset).to receive(:where).with(height: height).and_return(where_dataset)
      end

      it 'returns true when the merkle root matches' do
        allow(where_dataset).to receive(:first).and_return(merkle_root: merkle_root_bin)

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be true
      end

      it 'returns false when the merkle root does not match' do
        other_bin = [wrong_root_hex].pack('H*')
        allow(where_dataset).to receive(:first).and_return(merkle_root: other_bin)

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be false
      end

      it 'does not call the network' do
        allow(where_dataset).to receive(:first).and_return(merkle_root: merkle_root_bin)

        tracker.valid_root_for_height?(merkle_root_hex, height)
        expect(services).not_to have_received(:call)
      end
    end

    context 'when the block is not in the database (network fetch)' do
      before do
        allow(blocks_dataset).to receive(:where).with(height: height).and_return(where_dataset)
        allow(where_dataset).to receive(:first).and_return(nil)
      end

      it 'fetches from the network, persists, and returns true on match' do
        allow(services).to receive(:call).with(:get_block_header, height).and_return(
          success('merkleroot' => merkle_root_hex, 'hash' => block_hash_hex, 'height' => height)
        )

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be true
        expect(conflict_dataset).to have_received(:insert).with(
          height: height,
          merkle_root: Sequel.blob(merkle_root_bin),
          block_hash: Sequel.blob([block_hash_hex].pack('H*'))
        )
      end

      it 'returns false when the fetched root does not match' do
        allow(services).to receive(:call).with(:get_block_header, height).and_return(
          success('merkleroot' => wrong_root_hex, 'hash' => block_hash_hex, 'height' => height)
        )

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be false

        # Still persists the block (write-through is unconditional)
        expect(conflict_dataset).to have_received(:insert)
      end

      it 'returns false when the network call fails' do
        allow(services).to receive(:call).with(:get_block_header, height).and_return(error)

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be false
      end

      it 'returns false when the network raises an exception' do
        allow(services).to receive(:call).with(:get_block_header, height).and_raise(StandardError, 'timeout')

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be false
      end
    end

    context 'write-through cache behavior' do
      it 'hits the database on the second call, not the network' do
        allow(blocks_dataset).to receive(:where).with(height: height).and_return(where_dataset)

        # First call: DB miss, network fetch
        allow(where_dataset).to receive(:first).and_return(nil, { merkle_root: merkle_root_bin })
        allow(services).to receive(:call).with(:get_block_header, height).and_return(
          success('merkleroot' => merkle_root_hex, 'hash' => block_hash_hex, 'height' => height)
        )

        tracker.valid_root_for_height?(merkle_root_hex, height)

        # Second call: DB hit (simulated by returning a block row)
        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be true
        expect(services).to have_received(:call).with(:get_block_header, height).once
      end
    end

    context 'provider response field variations' do
      before do
        allow(blocks_dataset).to receive(:where).with(height: height).and_return(where_dataset)
        allow(where_dataset).to receive(:first).and_return(nil)
      end

      it 'handles Chaintracks-style merkleRoot field' do
        allow(services).to receive(:call).with(:get_block_header, height).and_return(
          success('merkleRoot' => merkle_root_hex, 'hash' => block_hash_hex)
        )

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be true
      end

      it 'handles responses without block_hash' do
        allow(services).to receive(:call).with(:get_block_header, height).and_return(
          success('merkleroot' => merkle_root_hex)
        )

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be true
        expect(conflict_dataset).to have_received(:insert).with(
          height: height,
          merkle_root: Sequel.blob(merkle_root_bin),
          block_hash: nil
        )
      end

      it 'returns false when response has no recognized merkle root field' do
        allow(services).to receive(:call).with(:get_block_header, height).and_return(
          success('unexpected_field' => 'value')
        )

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be false
      end
    end
  end

  describe '#current_height' do
    it 'returns the height from the network' do
      allow(services).to receive(:call).with(:current_height).and_return(success(850_000))

      expect(tracker.current_height).to eq(850_000)
    end

    it 'falls back to the DB max height when the network fails' do
      allow(services).to receive(:call).with(:current_height).and_return(error)
      allow(blocks_dataset).to receive(:max).with(:height).and_return(800_001)

      expect(tracker.current_height).to eq(800_001)
    end

    it 'falls back to the DB max height when the network raises' do
      allow(services).to receive(:call).with(:current_height).and_raise(StandardError, 'timeout')
      allow(blocks_dataset).to receive(:max).with(:height).and_return(800_000)

      expect(tracker.current_height).to eq(800_000)
    end

    it 'returns 0 when the DB is empty and the network fails' do
      allow(services).to receive(:call).with(:current_height).and_return(error)
      allow(blocks_dataset).to receive(:max).with(:height).and_return(nil)

      expect(tracker.current_height).to eq(0)
    end
  end
end
