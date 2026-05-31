# frozen_string_literal: true

# Logic-only unit test for the shared Fanout routing primitive. No DB,
# no network, no wallets — a recording block stands in for the transport,
# so this proves the routing contract that #129 (bin driver) and #126
# (in-process driver) both rely on, and runs in the unit matrix.

require_relative 'fanout'

RSpec.describe Fanout do
  describe '.pass' do
    let(:wallets) { %w[alice bob carol] }

    it 'sends count payments from every wallet to a not-self recipient' do
      hops = []
      log = described_class.pass(wallets: wallets, count: 4, satoshis: 5_000) do |sender, recipient, sats, i|
        hops << { sender: sender, recipient: recipient, sats: sats, i: i }
      end

      # count × wallet_count total hops
      expect(hops.length).to eq(12)
      # never self-routes
      expect(hops).to all(satisfy { |h| h[:sender] != h[:recipient] })
      # recipients are always drawn from the wallet set
      expect(hops.map { |h| h[:recipient] }.uniq - wallets).to be_empty
      # amount forwarded unchanged
      expect(hops.map { |h| h[:sats] }).to all(eq(5_000))
      # per-wallet index runs 0..count-1
      expect(hops.select { |h| h[:sender] == 'alice' }.map { |h| h[:i] }).to eq([0, 1, 2, 3])
      # the route log conserves the total
      expect(log.values.sum).to eq(12)
    end

    it 'raises when fewer than two wallets (cannot route not-self)' do
      expect { described_class.pass(wallets: %w[alice], count: 1, satoshis: 1) { nil } }
        .to raise_error(ArgumentError, /not-self/)
    end
  end

  describe '.run' do
    it 'runs one pass per [count, satoshis] level, returning a log each' do
      seen = []
      logs = described_class.run(wallets: %w[a b], passes: [[2, 50], [3, 10]]) do |_s, _r, sats, _i|
        seen << sats
      end

      expect(logs.length).to eq(2)
      # level 1: 2 × 2 wallets = 4 hops @ 50; level 2: 3 × 2 = 6 @ 10
      expect(seen.count(50)).to eq(4)
      expect(seen.count(10)).to eq(6)
      expect(logs.map { |l| l.values.sum }).to eq([4, 6])
    end
  end
end
