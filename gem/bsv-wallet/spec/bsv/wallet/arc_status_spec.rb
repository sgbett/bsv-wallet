# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BSV::Wallet::ArcStatus do
  describe 'ACCEPTED' do
    it 'lists the network-accepted statuses' do
      expect(described_class::ACCEPTED).to include('SEEN_ON_NETWORK', 'ACCEPTED_BY_NETWORK', 'MINED', 'IMMUTABLE')
    end

    it 'is frozen' do
      expect(described_class::ACCEPTED).to be_frozen
    end
  end

  describe 'REJECTED' do
    it 'lists the definitive-rejection statuses' do
      expect(described_class::REJECTED).to contain_exactly('REJECTED', 'DOUBLE_SPEND_ATTEMPTED')
    end

    # MALFORMED is not an ARC txStatus — ARC reports a malformed tx via an
    # HTTP 461/463 error, never as a status — so it must not leak into the
    # set that is matched against the persisted tx_status enum column.
    it 'excludes MALFORMED (an HTTP error, not a txStatus)' do
      expect(described_class::REJECTED).not_to include('MALFORMED')
    end

    it 'is frozen' do
      expect(described_class::REJECTED).to be_frozen
    end
  end

  describe 'TERMINAL' do
    it 'includes mined and rejected statuses' do
      expect(described_class::TERMINAL).to include('MINED', 'REJECTED')
    end

    it 'is frozen' do
      expect(described_class::TERMINAL).to be_frozen
    end

    # MINED_IN_STALE_BLOCK is transient: the tx is valid but on a fork, and
    # must continue to be re-polled until it lands on the main chain.
    # See docs/wallet-events.md and HLR #182.
    it 'excludes MINED_IN_STALE_BLOCK so stale-block rows keep being polled' do
      expect(described_class::TERMINAL).not_to include('MINED_IN_STALE_BLOCK')
    end

    # A rejected tx is never going to be accepted — polling must stop so
    # reject_action can unwind it.
    it 'includes every REJECTED status' do
      expect(described_class::TERMINAL).to include(*described_class::REJECTED)
    end

    # TERMINAL is matched against the persisted tx_status enum column in
    # Store#pending_resolutions; MALFORMED is an HTTP error, not a valid
    # enum value, so it must stay out or Postgres rejects the query.
    it 'excludes MALFORMED (not a valid tx_status enum value)' do
      expect(described_class::TERMINAL).not_to include('MALFORMED')
    end

    # ACCEPTED_BY_NETWORK is an interim accepted state: promote, but keep
    # polling until SEEN_ON_NETWORK / MINED yields the final proof.
    it 'excludes the interim ACCEPTED_BY_NETWORK state' do
      expect(described_class::TERMINAL).not_to include('ACCEPTED_BY_NETWORK')
    end
  end

  # The three sets were previously hand-mirrored across Engine,
  # Engine::Broadcast, and Models::Broadcast. Guard against any
  # reintroduced divergence: ACCEPTED and REJECTED are disjoint, and every
  # rejected-or-mined status the resolution loop should stop polling on is
  # terminal.
  it 'has disjoint ACCEPTED and REJECTED sets' do
    expect(described_class::ACCEPTED & described_class::REJECTED).to be_empty
  end
end
