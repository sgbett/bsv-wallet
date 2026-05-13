# frozen_string_literal: true

RSpec.describe BSV::Wallet::Pushable do
  subject(:instance) { klass.new }

  describe 'contract enforcement' do
    let(:klass) { Class.new { include BSV::Wallet::Pushable } }

    it 'raises NotImplementedError for #push_command' do
      expect { instance.push_command }.to raise_error(NotImplementedError, /push_command not implemented/)
    end

    it 'raises NotImplementedError for #push_payload' do
      expect { instance.push_payload }.to raise_error(NotImplementedError, /push_payload not implemented/)
    end

    it 'raises NotImplementedError for #write!' do
      expect { instance.write!({}) }.to raise_error(NotImplementedError, /write! not implemented/)
    end

    it 'raises NotImplementedError for #needs_push?' do
      expect { instance.needs_push? }.to raise_error(NotImplementedError, /needs_push\? not implemented/)
    end

    it 'includes the class name in the error message' do
      stub_const('MyBroadcast', klass)
      obj = MyBroadcast.new
      expect { obj.push_command }.to raise_error(NotImplementedError, /MyBroadcast#push_command/)
    end
  end

  describe 'implementing class' do
    let(:klass) do
      Class.new do
        include BSV::Wallet::Pushable

        def push_command = :broadcast
        def push_payload = 'raw_tx_bytes'
        def write!(_response) = :updated
        def needs_push? = true
      end
    end

    it 'returns the push command' do
      expect(instance.push_command).to eq(:broadcast)
    end

    it 'returns the push payload' do
      expect(instance.push_payload).to eq('raw_tx_bytes')
    end

    it 'calls write! without error' do
      expect(instance.write!(tx_status: 'SEEN_ON_NETWORK')).to eq(:updated)
    end

    it 'reports needs_push?' do
      expect(instance.needs_push?).to be true
    end
  end
end
