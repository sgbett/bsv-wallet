# frozen_string_literal: true

require 'spec_helper'
require 'bsv-wallet'

RSpec.describe BSV::Wallet::Engine::HydratedTxCache do
  let(:wtxid_a) { ("\x01" * 32).b }
  let(:wtxid_b) { ("\x02" * 32).b }
  let(:wtxid_c) { ("\x03" * 32).b }
  let(:raw_a) { 'raw-a'.b }
  let(:raw_b) { 'raw-b'.b }
  let(:raw_c) { 'raw-c'.b }
  let(:merkle) { 'merkle-bytes'.b }

  describe '#initialize' do
    it 'defaults to DEFAULT_CAPACITY' do
      expect(described_class.new.capacity).to eq(described_class::DEFAULT_CAPACITY)
    end

    it 'accepts a custom capacity' do
      expect(described_class.new(capacity: 5).capacity).to eq(5)
    end

    it 'rejects a negative capacity' do
      expect { described_class.new(capacity: -1) }.to raise_error(ArgumentError, /capacity must be >= 0/)
    end

    it 'allows capacity of 0 (always-miss cache)' do
      expect { described_class.new(capacity: 0) }.not_to raise_error
    end
  end

  describe '.from_config' do
    # Each example sets up Config via BSV::Wallet.config (which reads
    # ENV at initialize); reset between examples so the singleton
    # picks up the test's ENV mutation. ENV mutation save/restore via
    # +around+ keeps neighbouring examples honest.
    around do |example|
      saved = ENV.fetch('BSV_WALLET_TX_CACHE_SIZE', nil)
      BSV::Wallet.reset_config!
      example.run
    ensure
      saved.nil? ? ENV.delete('BSV_WALLET_TX_CACHE_SIZE') : ENV['BSV_WALLET_TX_CACHE_SIZE'] = saved
      BSV::Wallet.reset_config!
    end

    it 'uses Config default when BSV_WALLET_TX_CACHE_SIZE is unset' do
      ENV.delete('BSV_WALLET_TX_CACHE_SIZE')
      expect(described_class.from_config.capacity).to eq(described_class::DEFAULT_CAPACITY)
    end

    it 'reads BSV_WALLET_TX_CACHE_SIZE via Config (Integer)' do
      ENV['BSV_WALLET_TX_CACHE_SIZE'] = '250'
      expect(described_class.from_config.capacity).to eq(250)
    end

    it 'raises ArgumentError on a non-numeric value (fail loud, not silent)' do
      ENV['BSV_WALLET_TX_CACHE_SIZE'] = 'nope'
      # Failure now surfaces at Config#initialize, not at .from_config —
      # the cache constructor never sees a bad value.
      expect { BSV::Wallet.config }.to raise_error(ArgumentError, /invalid value for Integer/)
    end
  end

  describe '#get / #put' do
    let(:cache) { described_class.new(capacity: 10) }

    it 'returns nil for an unknown wtxid' do
      expect(cache.get(wtxid_a)).to be_nil
    end

    it 'returns the stored { raw_tx, merkle_path } after #put' do
      cache.put(wtxid_a, raw_tx: raw_a, merkle_path: merkle)
      expect(cache.get(wtxid_a)).to eq(raw_tx: raw_a, merkle_path: merkle)
    end

    it 'defaults merkle_path to nil (unconfirmed wire-up)' do
      cache.put(wtxid_a, raw_tx: raw_a)
      expect(cache.get(wtxid_a)).to eq(raw_tx: raw_a, merkle_path: nil)
    end

    it 'freezes the stored value (immutable snapshot)' do
      cache.put(wtxid_a, raw_tx: raw_a)
      expect(cache.get(wtxid_a)).to be_frozen
    end

    it 'is a no-op on capacity 0 (always miss)' do
      zero = described_class.new(capacity: 0)
      zero.put(wtxid_a, raw_tx: raw_a)
      expect(zero.get(wtxid_a)).to be_nil
      expect(zero.size).to eq(0)
    end
  end

  describe 'monotonic enrichment' do
    let(:cache) { described_class.new(capacity: 10) }

    it 'fills merkle_path in place when a proof arrives (put with the path)' do
      cache.put(wtxid_a, raw_tx: raw_a) # unconfirmed
      cache.put(wtxid_a, raw_tx: raw_a, merkle_path: merkle) # proof arrives
      expect(cache.get(wtxid_a)[:merkle_path]).to eq(merkle)
    end

    it 'never clears an already-present merkle_path (put with nil keeps it)' do
      cache.put(wtxid_a, raw_tx: raw_a, merkle_path: merkle)
      cache.put(wtxid_a, raw_tx: raw_a) # later wire-up without the path
      expect(cache.get(wtxid_a)[:merkle_path]).to eq(merkle)
    end
  end

  describe 'LRU eviction at capacity' do
    let(:cache) { described_class.new(capacity: 2) }

    it 'drops the least-recently-used entry when capacity is exceeded' do
      cache.put(wtxid_a, raw_tx: raw_a)
      cache.put(wtxid_b, raw_tx: raw_b)
      cache.put(wtxid_c, raw_tx: raw_c) # evicts the oldest (a)

      expect(cache.get(wtxid_a)).to be_nil
      expect(cache.get(wtxid_b)).to eq(raw_tx: raw_b, merkle_path: nil)
      expect(cache.get(wtxid_c)).to eq(raw_tx: raw_c, merkle_path: nil)
    end

    it '#get refreshes recency (touched entries survive the next eviction)' do
      cache.put(wtxid_a, raw_tx: raw_a)
      cache.put(wtxid_b, raw_tx: raw_b)
      cache.get(wtxid_a) # touch a; b is now least-recently-used
      cache.put(wtxid_c, raw_tx: raw_c) # evicts b instead of a

      expect(cache.get(wtxid_a)).to eq(raw_tx: raw_a, merkle_path: nil)
      expect(cache.get(wtxid_b)).to be_nil
      expect(cache.get(wtxid_c)).to eq(raw_tx: raw_c, merkle_path: nil)
    end

    it '#put refreshes recency (re-put entry survives the next eviction)' do
      cache.put(wtxid_a, raw_tx: raw_a)
      cache.put(wtxid_b, raw_tx: raw_b)
      cache.put(wtxid_a, raw_tx: raw_a, merkle_path: merkle) # touch a
      cache.put(wtxid_c, raw_tx: raw_c) # evicts b

      expect(cache.get(wtxid_a)[:merkle_path]).to eq(merkle)
      expect(cache.get(wtxid_b)).to be_nil
    end
  end

  describe '#size / #empty?' do
    let(:cache) { described_class.new(capacity: 5) }

    it 'tracks entry count across puts' do
      expect(cache.size).to eq(0)
      expect(cache).to be_empty
      cache.put(wtxid_a, raw_tx: raw_a)
      expect(cache.size).to eq(1)
      expect(cache).not_to be_empty
      cache.put(wtxid_b, raw_tx: raw_b)
      expect(cache.size).to eq(2)
    end
  end

  describe 'concurrent access (fiber safety under Mutex)' do
    it 'handles parallel put / get from multiple threads without raising' do
      cache = described_class.new(capacity: 100)
      threads = 4.times.map do |i|
        Thread.new do
          50.times do |j|
            wtxid = [(i * 100) + j].pack('N').b.ljust(32, "\x00")
            cache.put(wtxid, raw_tx: "raw-#{i}-#{j}".b)
            cache.get(wtxid)
          end
        end
      end
      expect { threads.each(&:join) }.not_to raise_error
      expect(cache.size).to be <= 100
    end
  end
end
