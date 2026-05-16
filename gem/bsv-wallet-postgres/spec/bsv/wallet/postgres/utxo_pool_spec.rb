# frozen_string_literal: true

RSpec.describe BSV::Wallet::Postgres::Store::UTXOPool do
  let(:store) { BSV::Wallet::Postgres::Store::Postgres.new }
  subject(:pool) { described_class.new(store: store) }

  def create_funded_output(satoshis: 1000, vout: 0, basket: 'default')
    source = BSV::Wallet::Postgres::Store::Action.create(outgoing: false, description: 'test action',
                                                  wtxid: SecureRandom.random_bytes(32),
                                                  raw_tx: SecureRandom.random_bytes(100))
    output = BSV::Wallet::Postgres::Store::Output.create(
      action_id: source.id, satoshis: satoshis, vout: vout,
      locking_script: SecureRandom.random_bytes(25),
      derivation_prefix: SecureRandom.uuid,
      derivation_suffix: '1',
      sender_identity_key: 'self'
    )
    BSV::Wallet::Postgres::Store::Spendable.create(output_id: output.id, action_id: source.id)
    unless basket == 'default'
      basket_id = store.find_or_create_basket(name: basket)
      BSV::Wallet::Postgres::Store::OutputBasket.create(output_id: output.id, basket_id: basket_id, action_id: source.id)
    end
    output
  end

  describe 'interface conformance' do
    it 'includes BSV::Wallet::Interface::UTXOPool' do
      expect(described_class.ancestors).to include(BSV::Wallet::Interface::UTXOPool)
    end
  end

  describe '#select' do
    before do
      create_funded_output(satoshis: 500, vout: 0)
      create_funded_output(satoshis: 300, vout: 0)
      create_funded_output(satoshis: 200, vout: 0)
    end

    it 'returns candidates sufficient for the requested amount' do
      candidates = pool.select(satoshis: 400)
      total = candidates.sum { |c| c[:satoshis] }
      expect(total).to be >= 400
    end

    it 'raises PoolDepletedError when insufficient funds' do
      expect { pool.select(satoshis: 99_999) }
        .to raise_error(BSV::Wallet::PoolDepletedError)
    end

    it 'respects exclude list' do
      all = pool.select(satoshis: 1)
      biggest_id = all.first[:id]

      candidates = pool.select(satoshis: 1, exclude: [biggest_id])
      expect(candidates.map { |c| c[:id] }).not_to include(biggest_id)
    end
  end

  describe '#release' do
    it 'is a no-op for tier 1' do
      expect { pool.release(outputs: [{ id: 1 }]) }.not_to raise_error
    end
  end

  describe '#balance' do
    it 'returns total spendable satoshis' do
      create_funded_output(satoshis: 500, vout: 0)
      create_funded_output(satoshis: 300, vout: 0)

      expect(pool.balance).to eq(800)
    end

    it 'returns 0 when no spendable outputs' do
      expect(pool.balance).to eq(0)
    end

    it 'excludes outputs locked by inputs' do
      output = create_funded_output(satoshis: 1000, vout: 0)
      create_funded_output(satoshis: 500, vout: 0)

      lock_action = BSV::Wallet::Postgres::Store::Action.create(outgoing: true, description: 'test action', nlocktime: 0)
      BSV::Wallet::Postgres::Store::Input.create(action_id: lock_action.id, output_id: output.id, vin: 0)

      expect(pool.balance).to eq(500)
    end
  end

  describe '#spendable_count' do
    it 'returns count of spendable outputs' do
      create_funded_output(satoshis: 500, vout: 0)
      create_funded_output(satoshis: 300, vout: 1)

      expect(pool.spendable_count).to eq(2)
    end

    it 'returns 0 when no spendable outputs' do
      expect(pool.spendable_count).to eq(0)
    end
  end

  describe '#change_output_count' do
    it 'returns max_change_per_tx for a rich wallet with empty pool' do
      # 1M sats, 0 UTXOs → target = min(500, 1000) = 500, deficit = 500
      create_funded_output(satoshis: 1_000_000, vout: 0)

      expect(pool.change_output_count).to eq(8)
    end

    it 'returns fewer when pool is approaching target' do
      # 100K sats across 97 UTXOs → target = min(500, 100) = 100, deficit = 3
      96.times { |i| create_funded_output(satoshis: 1_000, vout: i % 100) }
      create_funded_output(satoshis: 4_000, vout: 96)
      # 97 UTXOs, 100K sats → target 100, deficit 3

      expect(pool.change_output_count).to eq(3)
    end

    it 'returns 1 when pool is at target' do
      # 5K sats, 5 UTXOs → target = min(500, 5) = 5, deficit = 0 → clamp to 1
      5.times { |i| create_funded_output(satoshis: 1_000, vout: i) }

      expect(pool.change_output_count).to eq(1)
    end

    it 'returns 1 when pool exceeds target' do
      # 5K sats, 10 UTXOs → target = 5, deficit = -5 → clamp to 1
      10.times { |i| create_funded_output(satoshis: 500, vout: i) }

      expect(pool.change_output_count).to eq(1)
    end

    it 'respects min_utxo_sats floor for thin wallets' do
      # 3K sats → target = min(500, 3) = 3, not 500
      create_funded_output(satoshis: 3_000, vout: 0)

      expect(pool.change_output_count).to eq(2) # deficit = 3 - 1 = 2
    end

    it 'accepts config overrides' do
      create_funded_output(satoshis: 100_000, vout: 0)

      custom = described_class.new(
        store: store,
        max_utxo_count: 10,
        min_utxo_sats: 5_000,
        max_change_per_tx: 3
      )
      # target = min(10, 100000/5000) = 10, deficit = 10 - 1 = 9, clamped to 3
      expect(custom.change_output_count).to eq(3)
    end
  end
end
