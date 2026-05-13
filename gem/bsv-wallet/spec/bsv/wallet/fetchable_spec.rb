# frozen_string_literal: true

RSpec.describe BSV::Wallet::Fetchable do
  subject(:instance) { klass.new }

  describe 'contract enforcement' do
    let(:klass) { Class.new { include BSV::Wallet::Fetchable } }

    it 'raises NotImplementedError for #fetch_command' do
      expect { instance.fetch_command }.to raise_error(NotImplementedError, /fetch_command not implemented/)
    end

    it 'raises NotImplementedError for #fetch_args' do
      expect { instance.fetch_args }.to raise_error(NotImplementedError, /fetch_args not implemented/)
    end

    it 'raises NotImplementedError for #write!' do
      expect { instance.write!({}) }.to raise_error(NotImplementedError, /write! not implemented/)
    end

    it 'raises NotImplementedError for #needs_fetch?' do
      expect { instance.needs_fetch? }.to raise_error(NotImplementedError, /needs_fetch\? not implemented/)
    end

    it 'includes the class name in the error message' do
      stub_const('MyAction', klass)
      obj = MyAction.new
      expect { obj.fetch_command }.to raise_error(NotImplementedError, /MyAction#fetch_command/)
    end
  end

  describe 'implementing class' do
    let(:klass) do
      Class.new do
        include BSV::Wallet::Fetchable

        def fetch_command = :get_tx_status
        def fetch_args = { txid: 'abc123' }
        def write!(_response) = :updated
        def needs_fetch? = true
      end
    end

    it 'returns the fetch command' do
      expect(instance.fetch_command).to eq(:get_tx_status)
    end

    it 'returns the fetch args' do
      expect(instance.fetch_args).to eq(txid: 'abc123')
    end

    it 'calls write! without error' do
      expect(instance.write!(tx_status: 'MINED')).to eq(:updated)
    end

    it 'reports needs_fetch?' do
      expect(instance.needs_fetch?).to be true
    end
  end

  describe 'dual inclusion with Pushable' do
    let(:klass) do
      Class.new do
        include BSV::Wallet::Pushable
        include BSV::Wallet::Fetchable

        def push_command = :broadcast
        def push_payload = 'raw_tx_bytes'
        def fetch_command = :get_tx_status
        def fetch_args = { txid: 'abc123' }
        def write!(_response) = :updated
        def needs_push? = false
        def needs_fetch? = true
      end
    end

    it 'compiles without conflict' do
      expect(instance).to be_a(BSV::Wallet::Pushable)
      expect(instance).to be_a(described_class)
    end

    it 'has a single write! method' do
      expect(instance.write!({})).to eq(:updated)
    end

    it 'responds to all Pushable methods' do
      expect(instance.push_command).to eq(:broadcast)
      expect(instance.push_payload).to eq('raw_tx_bytes')
      expect(instance.needs_push?).to be false
    end

    it 'responds to all Fetchable methods' do
      expect(instance.fetch_command).to eq(:get_tx_status)
      expect(instance.fetch_args).to eq(txid: 'abc123')
      expect(instance.needs_fetch?).to be true
    end
  end
end
