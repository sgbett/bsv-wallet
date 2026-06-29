# frozen_string_literal: true

require 'spec_helper'
require_relative '../support/wallet_actor'

RSpec.describe 'wallet send (BEEF handover)' do # rubocop:disable RSpec/DescribeClass
  let(:src) { E2E::WalletActor.new(:sdk) }
  let(:dst) { E2E::WalletActor.new(:w1) }
  let(:sats) { 10_000_000 }

  before do # rubocop:disable RSpec/ScatteredSetup
    skip 'Missing BSV_WALLET_WIF_SDK' if ENV['BSV_WALLET_WIF_SDK'].to_s.strip.empty?
    skip 'Missing BSV_WALLET_POSTGRES' if ENV['BSV_WALLET_POSTGRES'].to_s.strip.empty?
    src.reset!
    dst.reset!
    src.import!
  end

  let!(:src_funds) { src.available_funds } # rubocop:disable RSpec/ScatteredLet
  let!(:dst_funds) { dst.available_funds } # rubocop:disable RSpec/ScatteredLet

  before do # rubocop:disable RSpec/ScatteredSetup
    envelope = src.send(dst.identity_key, sats)
    dst.receive(envelope)
  end

  it { expect(dst.available_funds).to eq(dst_funds + sats) }

  it 'sender funds drop by the payment amount plus the broadcast fee (within tolerance)' do
    # With HLR #467 in place +send.rb+ marks the outbound output
    # +spendable_intent: 'none'+ at construction time (no inference from
    # derivation columns); the engine cannot re-classify the recipient
    # output as wallet-owned. The sender balance therefore drops by
    # +sats + fee+. Fee at 100 sats/kb on a 1-in-2-out tx is in the
    # 25-100 sat range; we allow 1000 sats of headroom above +sats+ to
    # cover multi-input selection. The +>= sats+ lower bound is the
    # load-bearing regression guard — debit below +sats+ means the
    # recipient output is still being classified as sender-spendable
    # (the HLR #467 bug).
    debit = src_funds - src.available_funds
    expect(debit).to be_within(1000).of(sats)
    expect(debit).to be >= sats
  end
end
