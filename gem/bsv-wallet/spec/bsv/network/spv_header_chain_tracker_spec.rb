# frozen_string_literal: true

require_relative '../wallet/store/shared_context'
require_relative 'synthetic_chain'

# SpvHeaderChainTracker: PoW-validated chain tracker satisfying the SDK's
# ChainTracker duck type (#335). Driven by a deterministic synthetic
# regtest chain anchored at an injected checkpoint; +services.call+ stubbed
# per height. Real persistence (the +:store+ context) so the validated
# chain and tip are exercised through the store. SQLite by default;
# Postgres QA-verified.
RSpec.describe BSV::Network::SpvHeaderChainTracker, :store do
  subject(:tracker) do
    described_class.new(store: store, services: services, checkpoint: checkpoint)
  end

  let(:start_height) { 955_000 }
  # Enough headroom that height+100 (coinbase maturity) stays inside the chain.
  let(:chain)        { SyntheticChain.build(start_height: start_height, count: 260) }
  let(:checkpoint)   { SyntheticChain.checkpoint_for(chain, start_height) }
  let(:services)     { instance_double(BSV::Network::Services) }

  before do
    allow(services).to receive(:call) do |command, height|
      raise "unexpected command #{command}" unless command == :get_block_header

      chain.key?(height) ? SyntheticChain.success_response(chain[height]) : SyntheticChain.error_response
    end
  end

  # The display-hex merkle root the SDK would hand valid_root_for_height?
  # (compute_root_hex output) for the header at +height+.
  def display_root(height)
    chain[height].merkle_root.reverse.unpack1('H*')
  end

  describe '#valid_root_for_height?' do
    it 'returns true for a covered height with the correct root' do
      height = start_height + 10
      expect(tracker.valid_root_for_height?(display_root(height), height)).to be true
    end

    it 'returns false for a covered height with the WRONG root' do
      height = start_height + 10
      wrong = SecureRandom.random_bytes(32).unpack1('H*')
      expect(tracker.valid_root_for_height?(wrong, height)).to be false
    end

    it 'fails closed below the checkpoint height' do
      expect(tracker.valid_root_for_height?(display_root(start_height), start_height - 1)).to be false
    end

    it 'fails closed for a height the sync cannot reach (beyond the chain)' do
      # Within the DoS cap, but past the chain's supplied range: the service
      # 404s at the first missing height, the validated chain stops short, so
      # this height is never covered ⇒ not-covered path ⇒ false. (The chain
      # supplies 260 headers from start_height; 500 above is beyond it.)
      unreachable = start_height + 500
      expect(tracker.valid_root_for_height?(SecureRandom.hex(32), unreachable)).to be false
      # Proves it was the not-covered path, not the DoS bound: the chain DID
      # advance to its supplied tip rather than refusing to sync at all.
      expect(store.validated_tip(from_height: start_height)).to eq(start_height + 259)
    end

    it 'syncs once, then answers nearby heights from local reads (no further HTTP)' do
      first = start_height + 5
      expect(tracker.valid_root_for_height?(display_root(first), first)).to be true

      # A nearby height already covered by the +100 over-sync ⇒ no new fetch.
      allow(services).to receive(:call).and_raise('should not fetch on a covered height')
      near = start_height + 3
      expect(tracker.valid_root_for_height?(display_root(near), near)).to be true
    end

    it 'rescues unexpectedly and fails closed' do
      allow(store).to receive(:header_at).and_raise(StandardError, 'boom')
      height = start_height + 10
      expect(tracker.valid_root_for_height?(display_root(height), height)).to be false
    end
  end

  describe 'coinbase maturity (the +100 over-sync)' do
    # The tracker over-syncs to height+100, so current_height (the validated
    # tip) ends up ≥ 100 above any verified leaf — the SDK's coinbase
    # maturity rule (offset-0 leaf must be ≥ 100 blocks deep) is satisfied
    # for the leaves being verified.
    it 'a leaf 150 below the tip is mature: tip - leaf >= 100' do
      leaf = start_height + 10
      tracker.valid_root_for_height?(display_root(leaf), leaf)
      expect(tracker.current_height - leaf).to be >= 100
    end

    it 'the over-sync reaches leaf + 100 when the chain supplies it' do
      leaf = start_height + 50
      tracker.valid_root_for_height?(display_root(leaf), leaf)
      expect(store.header_at(height: leaf + 100)).to eq(chain[leaf + 100].raw)
    end
  end

  describe '#current_height' do
    it 'is the validated tip from the store, not a :current_height service call' do
      leaf = start_height + 20
      tracker.valid_root_for_height?(display_root(leaf), leaf)

      expect(tracker.current_height).to eq(store.validated_tip(from_height: start_height))
      # The dead :current_height Services call is never used.
      expect(services).not_to have_received(:call).with(:current_height)
    end

    it 'returns the checkpoint height before any sync has run' do
      expect(tracker.current_height).to eq(start_height)
    end
  end

  describe '#known_roots_for_heights (HLR #516 Sub 6.1)' do
    it 'returns wire-order 32-byte roots for covered heights' do
      heights = [start_height + 5, start_height + 10, start_height + 20]
      roots = tracker.known_roots_for_heights(heights)
      heights.each do |h|
        expect(roots[h]).to eq(chain[h].merkle_root)
        expect(roots[h].bytesize).to eq(32)
      end
    end

    it 'returns nil for heights outside the validated range (unknown, not mismatch)' do
      unreachable = start_height + 500 # sync 404s before reaching here
      roots = tracker.known_roots_for_heights([unreachable])
      expect(roots).to eq(unreachable => nil)
    end

    it 'returns nil for heights below the checkpoint' do
      roots = tracker.known_roots_for_heights([start_height - 1])
      expect(roots).to eq(start_height - 1 => nil)
    end

    it 'is a no-op on empty input (no sync, empty Hash)' do
      expect(tracker.known_roots_for_heights([])).to eq({})
    end

    it 'costs one sync per batch and shares coverage across nearby batches' do
      # First batch: sync extends chain to max(heights) + MATURITY_HEADROOM.
      tracker.known_roots_for_heights([start_height + 5, start_height + 6, start_height + 7])
      fetch_count = 0
      allow(services).to receive(:call) do |command, height|
        fetch_count += 1
        raise "unexpected command #{command}" unless command == :get_block_header

        chain.key?(height) ? SyntheticChain.success_response(chain[height]) : SyntheticChain.error_response
      end
      # Second batch entirely within the already-covered range (max ≤
      # first batch's max) — no new fetches; the syncer answers from
      # already-persisted headers.
      tracker.known_roots_for_heights([start_height + 3, start_height + 7])
      expect(fetch_count).to eq(0)
    end

    it 'returns nil for every requested height when sync raises' do
      allow(services).to receive(:call).and_raise(StandardError, 'network boom')
      heights = [start_height + 5, start_height + 6]
      roots = tracker.known_roots_for_heights(heights)
      expect(roots).to eq(heights.to_h { |h| [h, nil] })
    end
  end

  describe 'network override' do
    it 'falls back to the baked-in mainnet checkpoint when no override is given' do
      real = described_class.new(store: store, services: services, network: :mainnet)
      # Below the real mainnet checkpoint (955000) ⇒ fail-closed, no fetch.
      expect(real.valid_root_for_height?(SecureRandom.hex(32), 1)).to be false
    end
  end
end
