# frozen_string_literal: true

RSpec.describe BSV::Wallet::Postgres::UTXOPool do
  let(:store) { BSV::Wallet::Postgres::Store.new }
  subject(:pool) { described_class.new(store: store) }

  def create_funded_output(satoshis: 1000, vout: 0, basket: 'default')
    source = BSV::Wallet::Postgres::Action.create(outgoing: false, description: 'test action',
                                                  wtxid: SecureRandom.random_bytes(32),
                                                  raw_tx: SecureRandom.random_bytes(100))
    output = BSV::Wallet::Postgres::Output.create(
      action_id: source.id, satoshis: satoshis, vout: vout,
      locking_script: SecureRandom.random_bytes(25),
      output_type: 'root'
    )
    BSV::Wallet::Postgres::Spendable.create(output_id: output.id, action_id: source.id)
    unless basket == 'default'
      basket_id = store.find_or_create_basket(name: basket)
      BSV::Wallet::Postgres::OutputBasket.create(output_id: output.id, basket_id: basket_id, action_id: source.id)
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

      lock_action = BSV::Wallet::Postgres::Action.create(outgoing: true, description: 'test action')
      BSV::Wallet::Postgres::Input.create(action_id: lock_action.id, output_id: output.id, vin: 0)

      expect(pool.balance).to eq(500)
    end
  end
end
