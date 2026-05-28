# frozen_string_literal: true

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

  # Non-palindromic hex fixtures — reversing byte order produces a different
  # value, which catches byte-order bugs that palindromic strings (e.g. 'aa...')
  # would miss.
  #
  # Convention:
  #   - +merkle_root_hex+: display-order hex (the SDK's MerklePath#compute_root_hex
  #     output and WoC's API payload — what the ChainTracker accepts at its boundaries).
  #   - +merkle_root_wire+: wire-order bytes (reverse) — what the +blocks+ table stores
  #     internally, matching the wtxid convention.
  let(:merkle_root_hex)   { '0123456789abcdef' * 4 }
  let(:merkle_root_wire)  { [merkle_root_hex].pack('H*').reverse }
  let(:wrong_root_hex)    { 'fedcba9876543210' * 4 }
  let(:wrong_root_wire)   { [wrong_root_hex].pack('H*').reverse }
  let(:block_hash_hex)    { 'abcdef0123456789' * 4 }
  let(:block_hash_wire)   { [block_hash_hex].pack('H*').reverse }
  let(:height)            { 800_000 }

  let(:services) { instance_double(BSV::Network::Services, call: nil) }

  # Plain double — instance_double(BSV::Wallet::Store) triggers autoloading
  # of Store::Models which requires a live Sequel connection.
  let(:store) do
    double('store', find_block: nil, max_block_height: nil, record_block_header: nil)
  end

  let(:tracker) { described_class.new(store: store, services: services) }

  describe '#valid_root_for_height?' do
    context 'when the block exists in the store' do
      it 'returns true when the merkle root matches' do
        allow(store).to receive(:find_block).with(height: height)
                                            .and_return(merkle_root: merkle_root_wire)

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be true
      end

      it 'returns false when the merkle root does not match' do
        allow(store).to receive(:find_block).with(height: height)
                                            .and_return(merkle_root: wrong_root_wire)

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be false
      end

      it 'does not call the network' do
        allow(store).to receive(:find_block).with(height: height)
                                            .and_return(merkle_root: merkle_root_wire)

        tracker.valid_root_for_height?(merkle_root_hex, height)
        expect(services).not_to have_received(:call)
      end
    end

    context 'when the block is not in the store (network fetch)' do
      it 'fetches from the network, persists, and returns true on match' do
        allow(services).to receive(:call).with(:get_block_header, height).and_return(
          success('merkleroot' => merkle_root_hex, 'hash' => block_hash_hex, 'height' => height)
        )

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be true
        expect(store).to have_received(:record_block_header).with(
          height: height,
          merkle_root: merkle_root_wire,
          block_hash: block_hash_wire
        )
      end

      it 'returns false when the fetched root does not match' do
        allow(services).to receive(:call).with(:get_block_header, height).and_return(
          success('merkleroot' => wrong_root_hex, 'hash' => block_hash_hex, 'height' => height)
        )

        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be false

        # Still persists the block (write-through is unconditional)
        expect(store).to have_received(:record_block_header)
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
      it 'hits the store on the second call, not the network' do
        # First call: store miss, network fetch
        allow(store).to receive(:find_block).with(height: height)
                                            .and_return(nil, { merkle_root: merkle_root_wire })
        allow(services).to receive(:call).with(:get_block_header, height).and_return(
          success('merkleroot' => merkle_root_hex, 'hash' => block_hash_hex, 'height' => height)
        )

        tracker.valid_root_for_height?(merkle_root_hex, height)

        # Second call: store hit (simulated by returning a block row)
        expect(tracker.valid_root_for_height?(merkle_root_hex, height)).to be true
        expect(services).to have_received(:call).with(:get_block_header, height).once
      end
    end

    context 'provider response field variations' do
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
        expect(store).to have_received(:record_block_header).with(
          height: height,
          merkle_root: merkle_root_wire,
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

    it 'falls back to the store max height when the network fails' do
      allow(services).to receive(:call).with(:current_height).and_return(error)
      allow(store).to receive(:max_block_height).and_return(800_001)

      expect(tracker.current_height).to eq(800_001)
    end

    it 'falls back to the store max height when the network raises' do
      allow(services).to receive(:call).with(:current_height).and_raise(StandardError, 'timeout')
      allow(store).to receive(:max_block_height).and_return(800_000)

      expect(tracker.current_height).to eq(800_000)
    end

    it 'returns 0 when the store is empty and the network fails' do
      allow(services).to receive(:call).with(:current_height).and_return(error)

      expect(tracker.current_height).to eq(0)
    end
  end
end
