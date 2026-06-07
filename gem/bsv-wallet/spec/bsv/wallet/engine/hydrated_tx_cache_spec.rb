# frozen_string_literal: true

require 'spec_helper'
require 'bsv-wallet'

RSpec.describe BSV::Wallet::Engine::HydratedTxCache do
  let(:alpha_tx) { instance_double(BSV::Transaction::Transaction, wtxid: ("\x01" * 32).b) }
  let(:beta_tx) { instance_double(BSV::Transaction::Transaction, wtxid: ("\x02" * 32).b) }
  let(:gamma_tx) { instance_double(BSV::Transaction::Transaction, wtxid: ("\x03" * 32).b) }

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

    it 'uses Config default (1000) when BSV_WALLET_TX_CACHE_SIZE is unset' do
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

    it 'returns nil for an unknown key' do
      expect(cache.get(42)).to be_nil
    end

    it 'returns the stored value after #put' do
      cache.put(1, alpha_tx)
      expect(cache.get(1)).to eq(alpha_tx)
    end

    it '#put overwrites a previous value for the same key' do
      cache.put(1, alpha_tx)
      cache.put(1, beta_tx)
      expect(cache.get(1)).to eq(beta_tx)
    end

    it 'is a no-op on capacity 0 (always miss)' do
      zero = described_class.new(capacity: 0)
      zero.put(1, alpha_tx)
      expect(zero.get(1)).to be_nil
      expect(zero.size).to eq(0)
    end
  end

  describe '#evict' do
    let(:cache) { described_class.new(capacity: 10) }

    it 'removes the entry for the given key' do
      cache.put(1, alpha_tx)
      cache.evict(1)
      expect(cache.get(1)).to be_nil
    end

    it 'is a no-op for an unknown key' do
      expect { cache.evict(999) }.not_to raise_error
    end
  end

  describe 'LRU eviction at capacity' do
    let(:cache) { described_class.new(capacity: 2) }

    it 'drops the least-recently-used entry when capacity is exceeded' do
      cache.put(1, alpha_tx)
      cache.put(2, beta_tx)
      cache.put(3, gamma_tx) # evicts the oldest (1)

      expect(cache.get(1)).to be_nil
      expect(cache.get(2)).to eq(beta_tx)
      expect(cache.get(3)).to eq(gamma_tx)
    end

    it '#get refreshes recency (touched entries survive the next eviction)' do
      cache.put(1, alpha_tx)
      cache.put(2, beta_tx)
      cache.get(1) # touch 1; 2 is now least-recently-used
      cache.put(3, gamma_tx) # evicts 2 instead of 1

      expect(cache.get(1)).to eq(alpha_tx)
      expect(cache.get(2)).to be_nil
      expect(cache.get(3)).to eq(gamma_tx)
    end
  end

  describe '#size / #empty?' do
    let(:cache) { described_class.new(capacity: 5) }

    it 'tracks entry count across put / evict' do
      expect(cache.size).to eq(0)
      expect(cache).to be_empty
      cache.put(1, alpha_tx)
      expect(cache.size).to eq(1)
      expect(cache).not_to be_empty
      cache.evict(1)
      expect(cache).to be_empty
    end
  end

  describe 'concurrent access (fiber safety under Mutex)' do
    it 'handles parallel put / get from multiple fibers without raising' do
      cache = described_class.new(capacity: 100)
      threads = 4.times.map do |i|
        Thread.new do
          50.times do |j|
            cache.put((i * 100) + j, instance_double(BSV::Transaction::Transaction))
            cache.get((i * 100) + j)
          end
        end
      end
      expect { threads.each(&:join) }.not_to raise_error
      expect(cache.size).to be <= 100
    end
  end
end
