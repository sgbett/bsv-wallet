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
    envelope = src.send(dst.identity_key, sats, no_fee: true)
    dst.receive(envelope)
  end

  it { expect(dst.available_funds).to eq(dst_funds + sats) }
  it { expect(src.available_funds).to eq(src_funds - sats) }
end
