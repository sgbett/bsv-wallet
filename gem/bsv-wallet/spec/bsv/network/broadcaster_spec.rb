# frozen_string_literal: true

require 'net/http'

RSpec.describe BSV::Network::Broadcaster do
  before do
    # Suppress backoff sleeps from the underlying Services composition so the
    # retryable-fallback spec doesn't wait on real wall-clock delay.
    allow_any_instance_of(BSV::Network::Services).to receive(:backoff_sleep) # rubocop:disable RSpec/AnyInstance
  end

  let(:wtxid) { ("\x00" * 32).b }

  def stub_provider(name, commands_hash, rate_limit: nil)
    commands_set = Set.new(commands_hash.keys)
    provider = instance_double(BSV::Network::Provider,
                               name: name,
                               commands: commands_set,
                               rate_limit: rate_limit)
    commands_hash.each do |cmd, result|
      allow(provider).to receive(:call).with(cmd, any_args).and_return(result)
    end
    provider
  end

  def success(data)
    BSV::Network::ProtocolResponse.new(nil, data: data, http_success: true)
  end

  def error(message, retryable: false)
    http_resp = instance_double(Net::HTTPResponse).tap do |r|
      allow(r).to receive(:is_a?).and_return(false)
      allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(r).to receive(:is_a?).with(Net::HTTPNotFound).and_return(false)
      allow(r).to receive(:is_a?).with(Net::HTTPTooManyRequests).and_return(retryable)
      allow(r).to receive(:is_a?).with(Net::HTTPServerError).and_return(false)
    end
    BSV::Network::ProtocolResponse.new(http_resp, http_success: false, error_message: message)
  end

  describe '#initialize' do
    it 'requires at least one provider' do
      expect { described_class.new(providers: []) }.to raise_error(ArgumentError)
    end

    it 'rejects nil providers' do
      expect { described_class.new(providers: nil) }.to raise_error(ArgumentError)
    end

    it 'accepts a store kwarg for affinity persistence (used in Task 3+)' do
      provider = stub_provider('ARC', { broadcast: success({ 'txid' => 'abc' }) })
      broadcaster = described_class.new(providers: [provider], store: :fake_store)
      expect(broadcaster.store).to eq(:fake_store)
    end

    it 'freezes the providers list' do
      provider = stub_provider('ARC', { broadcast: success({ 'txid' => 'abc' }) })
      broadcaster = described_class.new(providers: [provider])
      expect(broadcaster.providers).to be_frozen
    end
  end

  describe '#broadcast' do
    it 'returns a successful ProtocolResponse when the first provider succeeds' do
      provider = stub_provider('ARC', {
                                 broadcast: success({ 'txid' => 'abc', 'txStatus' => 'SEEN_ON_NETWORK' })
                               })
      broadcaster = described_class.new(providers: [provider])

      result = broadcaster.broadcast('rawtx', wtxid: wtxid)

      expect(result).to be_a(BSV::Network::ProtocolResponse)
      expect(result.http_success?).to be true
      expect(result.data[:txid]).to eq('abc')
      expect(result.data[:tx_status]).to eq('SEEN_ON_NETWORK')
    end

    it 'falls back to the next provider on retryable error' do
      failing = stub_provider('P1', { broadcast: error('rate limited', retryable: true) })
      working = stub_provider('P2', { broadcast: success({ 'txid' => 'abc' }) })
      broadcaster = described_class.new(providers: [failing, working])

      result = broadcaster.broadcast('rawtx', wtxid: wtxid)

      expect(result.http_success?).to be true
      expect(result.data[:txid]).to eq('abc')
    end

    it 'returns a synthetic no-provider response when no provider serves :broadcast' do
      provider = stub_provider('WoC', { get_tx: success('deadbeef') })
      broadcaster = described_class.new(providers: [provider])

      result = broadcaster.broadcast('rawtx', wtxid: wtxid)

      expect(result.http_success?).to be false
      expect(result.error_message).to match(/no provider/)
    end

    it 'accepts a Transaction-shaped payload (inline path) without narrowing' do
      tx_object = double('Transaction', wtxid: wtxid)
      provider = stub_provider('ARC', { broadcast: success({ 'txid' => 'abc' }) })
      broadcaster = described_class.new(providers: [provider])

      broadcaster.broadcast(tx_object, wtxid: wtxid)

      expect(provider).to have_received(:call).with(:broadcast, tx_object)
    end

    it 'accepts raw bytes as payload (daemon path)' do
      provider = stub_provider('ARC', { broadcast: success({ 'txid' => 'abc' }) })
      broadcaster = described_class.new(providers: [provider])

      broadcaster.broadcast("\x01\x02\x03".b, wtxid: wtxid)

      expect(provider).to have_received(:call).with(:broadcast, "\x01\x02\x03".b)
    end

    it 'requires the wtxid kwarg' do
      provider = stub_provider('ARC', { broadcast: success({ 'txid' => 'abc' }) })
      broadcaster = described_class.new(providers: [provider])

      expect { broadcaster.broadcast('rawtx') }.to raise_error(ArgumentError, /wtxid/)
    end
  end

  describe '#provider_for' do
    it 'returns nil until Task 3 wires DB-backed affinity' do
      provider = stub_provider('ARC', { broadcast: success({ 'txid' => 'abc' }) })
      broadcaster = described_class.new(providers: [provider])

      expect(broadcaster.provider_for(wtxid)).to be_nil
    end
  end
end
