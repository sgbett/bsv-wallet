# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../support/e2e/wallet_actor'

RSpec.describe 'transmit', :e2e do # rubocop:disable RSpec/DescribeClass
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    E2E::WalletActor.install!
    E2E::WalletActor.new(:sdk).import!
  end

  describe 'simple transmit' do
    before(:all) { E2E::WalletActor.new(:w1).reset! } # rubocop:disable RSpec/BeforeAfterAll

    let(:src) { E2E::WalletActor.new(:sdk) }
    let(:dst) { E2E::WalletActor.new(:w1) }
    let(:sats) { 10_000_000 }
    # Generous upper bound on a 1-input → 2-output P2PKH fee at 100 sat/KB.
    let(:max_fee) { 1_000 }
    let(:sats_received) { sats - max_fee }

    let!(:src_funds) { src.available_funds }
    let!(:dst_funds) { dst.available_funds }

    before do
      envelope = src.create(dst.identity_key, sats)
      dst.internalize(envelope)
    end

    it { expect(src.available_funds).to be < (src_funds - sats_received) }
    it { expect(dst.available_funds).to be > (dst_funds + sats_received) }
  end
end
