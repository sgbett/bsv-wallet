# frozen_string_literal: true

require 'net/http'
require 'sequel' # +persist_block+ rescues +Sequel::Error+ — constant must resolve in the spec harness

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

  describe '#known_roots_for_heights (HLR #516 Sub 6.1)' do
    # #535 — anchor-liveness must see the CURRENT chain view, not
    # whatever the wallet has seen so far. Bypass the +blocks+ cache
    # (set at proof-import time, never auto-refreshed on the
    # trusted-service model) and fetch fresh. Without this, a re-org
    # at a height with a cached +blocks+ row would go undetected on the
    # trusted-service tracker path.
    it 'bypasses the store cache and fetches fresh even when a blocks row exists' do
      stale_root = SecureRandom.random_bytes(32)
      allow(store).to receive(:find_block).with(height: height)
                                          .and_return(merkle_root: stale_root)
      allow(services).to receive(:call).with(:get_block_header, height).and_return(
        success('merkleroot' => merkle_root_hex, 'hash' => block_hash_hex)
      )

      result = tracker.known_roots_for_heights([height])
      expect(result[height]).to eq(merkle_root_wire) # fresh, not the stale cached root
      expect(services).to have_received(:call).with(:get_block_header, height)
    end

    it 'falls back to the network on a store miss and persists the fetched header' do
      allow(store).to receive(:find_block).with(height: height).and_return(nil)
      allow(services).to receive(:call).with(:get_block_header, height).and_return(
        success('merkleroot' => merkle_root_hex, 'hash' => block_hash_hex)
      )

      result = tracker.known_roots_for_heights([height])
      expect(result[height]).to eq(merkle_root_wire)
      expect(store).to have_received(:record_block_header).with(
        height: height, merkle_root: merkle_root_wire, block_hash: block_hash_wire
      )
    end

    it 'maps nil for a height the network cannot resolve (unknown ≠ mismatch)' do
      allow(store).to receive(:find_block).with(height: height).and_return(nil)
      allow(services).to receive(:call).with(:get_block_header, height).and_return(error)

      expect(tracker.known_roots_for_heights([height])).to eq(height => nil)
    end

    it 'maps nil when the network response has no recognised root field' do
      allow(store).to receive(:find_block).with(height: height).and_return(nil)
      allow(services).to receive(:call).with(:get_block_header, height).and_return(
        success('unexpected' => 'value')
      )

      expect(tracker.known_roots_for_heights([height])).to eq(height => nil)
    end

    it 'is a no-op on empty input' do
      expect(tracker.known_roots_for_heights([])).to eq({})
      expect(services).not_to have_received(:call)
    end

    it 'rescues per-height failures and yields nil for the erroring height' do
      allow(store).to receive(:find_block).with(height: height).and_return(nil)
      allow(services).to receive(:call).with(:get_block_header, height).and_raise(StandardError, 'boom')

      expect(tracker.known_roots_for_heights([height])).to eq(height => nil)
    end

    # Copilot on #533. Ruby's +pack('H*')+ silently coerces
    # odd-length / non-hex input, so an unvalidated malformed
    # +merkleroot+ would corrupt anchor-liveness. Treat malformed as
    # "unknown" (nil), not a distorted binary root.
    it 'maps nil when merkleroot is not 64-char hex (malformed field)' do
      allow(store).to receive(:find_block).with(height: height).and_return(nil)
      allow(services).to receive(:call).with(:get_block_header, height).and_return(
        success('merkleroot' => 'deadbee') # odd length, would silently pad
      )

      expect(tracker.known_roots_for_heights([height])).to eq(height => nil)
      expect(store).not_to have_received(:record_block_header)
    end

    it 'maps nil when merkleroot contains non-hex characters' do
      allow(store).to receive(:find_block).with(height: height).and_return(nil)
      allow(services).to receive(:call).with(:get_block_header, height).and_return(
        success('merkleroot' => "zzzz#{'0' * 60}")
      )

      expect(tracker.known_roots_for_heights([height])).to eq(height => nil)
    end

    it 'ignores a malformed block_hash while accepting a valid merkleroot' do
      allow(store).to receive(:find_block).with(height: height).and_return(nil)
      allow(services).to receive(:call).with(:get_block_header, height).and_return(
        success('merkleroot' => merkle_root_hex, 'hash' => 'not-hex')
      )

      result = tracker.known_roots_for_heights([height])
      expect(result[height]).to eq(merkle_root_wire)
      # block_hash treated as nil rather than silently persisting a corrupted value.
      expect(store).to have_received(:record_block_header).with(
        height: height, merkle_root: merkle_root_wire, block_hash: nil
      )
    end

    # #533 code-review — the earlier broad +rescue StandardError+
    # swallowed +CompetingBlockHeaderError+ (raised by
    # +record_block_header+ when the persisted +blocks+ row disagrees
    # with the fetched header — a real re-org signal). Now caught by
    # a distinct clause that logs at +warn+ with +cause=competing_header+
    # so operators can distinguish a fork from a transient outage.
    it 'logs cause=competing_header when persist_block detects a fork' do
      allow(store).to receive(:find_block).with(height: height).and_return(nil)
      allow(services).to receive(:call).with(:get_block_header, height).and_return(
        success('merkleroot' => merkle_root_hex, 'hash' => block_hash_hex)
      )
      allow(store).to receive(:record_block_header).and_raise(
        BSV::Wallet::CompetingBlockHeaderError.new(height)
      )
      logger = double('logger')
      captured = []
      allow(logger).to receive(:warn) { |&block| captured << block.call }
      allow(BSV).to receive(:logger).and_return(logger)

      result = tracker.known_roots_for_heights([height])

      expect(result).to eq(height => nil) # caller sees "unknown"
      expect(captured.join).to include('cause=competing_header')
    end
  end
end
