# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../support/e2e/wallet_actor'

RSpec.describe 'transmit', :e2e do # rubocop:disable RSpec/DescribeClass
  before(:all) { E2E::WalletActor.install! } # rubocop:disable RSpec/BeforeAfterAll

  describe 'simple transmit' do
    let(:src) { E2E::WalletActor.new(:sdk) }
    let(:dst) { E2E::WalletActor.new(:w1) }
    let(:sats) { 10_000_000 }

    before do # rubocop:disable RSpec/ScatteredSetup
      src.reset!
      dst.reset!
      src.import!
    end

    let!(:src_funds) { src.available_funds } # rubocop:disable RSpec/ScatteredLet
    let!(:dst_funds) { dst.available_funds } # rubocop:disable RSpec/ScatteredLet

    before do # rubocop:disable RSpec/ScatteredSetup
      envelope = src.create(dst.identity_key, sats)
      dst.internalize(envelope)
    end

    # Recipient gains exactly the payment output. No fee deducted on
    # receive — fees come off the sender's change.
    it { expect(dst.available_funds).to eq(dst_funds + sats) }

    # Sender pays `sats` plus the network fee. We don't compute the exact
    # fee here (parsing the BEEF would give it); the spec just asserts at
    # least `sats` was deducted, which holds regardless of fee size.
    it { expect(src.available_funds).to be <= (src_funds - sats) }
  end
end
