# frozen_string_literal: true

RSpec.describe BSV::Wallet::TrustedSelfChainTracker do
  subject(:tracker) { described_class.new }

  describe '#valid_root_for_height?' do
    it 'returns true for any root/height pair (structural-only, egress use)' do
      expect(tracker.valid_root_for_height?('any-root', 100)).to be true
    end
  end

  describe '#current_height' do
    it 'returns SENTINEL_HEIGHT (well above coinbase maturity)' do
      expect(tracker.current_height).to eq(described_class::SENTINEL_HEIGHT)
    end
  end

  # HLR #516 Sub 6.1 stub. The trusted-self tracker is egress-only and
  # must never invalidate an ingress trust set — every height maps to
  # nil ("unknown") so that if a call site mis-wires this tracker into
  # +Engine::AnchorLivenessCache+ the pathological result is a no-op,
  # not a false invalidation.
  describe '#known_roots_for_heights (HLR #516 Sub 6.1)' do
    it 'returns nil for every height (unknown, safe)' do
      heights = [100, 200, 300]
      expect(tracker.known_roots_for_heights(heights)).to eq(
        heights.to_h { |h| [h, nil] }
      )
    end

    it 'is a no-op on empty input' do
      expect(tracker.known_roots_for_heights([])).to eq({})
    end
  end
end
