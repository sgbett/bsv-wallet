# frozen_string_literal: true

require 'net/http'
require 'base64'

RSpec.describe BSV::Network::Services do
  # Skip backoff sleeps in tests — retry behaviour is asserted via call counts
  # and final results; we don't need the real wall-clock delay here. Pinned
  # to BSV::Network::Services explicitly so the stub doesn't bleed onto the
  # nested TokenBucket describe (which has no backoff_sleep).
  before do
    # Pinned to BSV::Network::Services explicitly (not described_class) so the
    # stub doesn't bleed onto the nested TokenBucket describe, which has no
    # backoff_sleep.
    allow_any_instance_of(BSV::Network::Services).to receive(:backoff_sleep) # rubocop:disable RSpec/AnyInstance,RSpec/DescribedClass
  end

  # --- Test helpers ---

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

  def not_found(message = 'not found')
    http_resp = instance_double(Net::HTTPResponse).tap do |r|
      allow(r).to receive(:is_a?).and_return(false)
      allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(r).to receive(:is_a?).with(Net::HTTPNotFound).and_return(true)
      allow(r).to receive(:is_a?).with(Net::HTTPTooManyRequests).and_return(false)
      allow(r).to receive(:is_a?).with(Net::HTTPServerError).and_return(false)
    end
    BSV::Network::ProtocolResponse.new(http_resp, http_success: false, error_message: message)
  end

  # --- Construction ---

  describe '#initialize' do
    it 'requires at least one provider' do
      expect { described_class.new(providers: []) }.to raise_error(ArgumentError)
    end

    it 'rejects nil providers' do
      expect { described_class.new(providers: nil) }.to raise_error(ArgumentError)
    end
  end

  # --- Basic routing ---

  describe '#call' do
    it 'routes to a single provider and returns the result' do
      provider = stub_provider('WoC', { get_tx: success('deadbeef') })
      services = described_class.new(providers: [provider])

      result = services.call(:get_tx, 'abc123')
      expect(result.http_success?).to be true
    end

    it 'skips providers that do not serve the command' do
      arc = stub_provider('ARC', { broadcast: success({ 'txid' => 'x', 'txStatus' => 'SEEN_ON_NETWORK' }) })
      woc = stub_provider('WoC', { get_utxos: success([{ 'tx_hash' => 'abc' }]) })
      services = described_class.new(providers: [arc, woc])

      result = services.call(:get_utxos, 'addr')
      expect(result.http_success?).to be true
      expect(result.data).to be_a(Array)
    end

    it 'returns first successful provider result' do
      p1 = stub_provider('P1', { get_tx: success('from_p1') })
      p2 = stub_provider('P2', { get_tx: success('from_p2') })
      services = described_class.new(providers: [p1, p2])

      result = services.call(:get_tx, 'txid')
      expect(result.data).to eq('from_p1')
    end
  end

  # --- Fallback ---

  describe 'fallback behavior' do
    it 'falls back to next provider on retryable error' do
      failing = stub_provider('P1', { get_tx: error('timeout', retryable: true) })
      working = stub_provider('P2', { get_tx: success('from_p2') })
      services = described_class.new(providers: [failing, working])

      result = services.call(:get_tx, 'txid')
      expect(result.http_success?).to be true
      expect(result.data).to eq('from_p2')
    end

    it 'does not fall back on non-retryable error' do
      failing = stub_provider('P1', { get_tx: error('bad request', retryable: false) })
      working = stub_provider('P2', { get_tx: success('from_p2') })
      services = described_class.new(providers: [failing, working])

      result = services.call(:get_tx, 'txid')
      expect(result.http_success?).to be false
      expect(result.error_message).to eq('bad request')
    end

    it 'treats NotFound as terminal' do
      nf = stub_provider('P1', { get_tx: not_found })
      working = stub_provider('P2', { get_tx: success('from_p2') })
      services = described_class.new(providers: [nf, working])

      result = services.call(:get_tx, 'txid')
      expect(result.http_not_found?).to be true
    end

    it 'returns last error when all providers fail' do
      p1 = stub_provider('P1', { get_tx: error('p1 down', retryable: true) })
      p2 = stub_provider('P2', { get_tx: error('p2 down', retryable: true) })
      services = described_class.new(providers: [p1, p2])

      result = services.call(:get_tx, 'txid')
      expect(result.http_success?).to be false
      expect(result.error_message).to eq('p2 down')
    end

    it 'returns error when no provider serves the command' do
      provider = stub_provider('ARC', { broadcast: success({}) })
      services = described_class.new(providers: [provider])

      result = services.call(:get_utxos, 'addr')
      expect(result.http_success?).to be false
      expect(result.error_message).to match(/no provider/)
    end
  end

  # --- Per-Provider Backoff Retry ---

  describe 'backoff retry on retryable responses' do
    it 'retries the same provider up to RETRYABLE_ATTEMPTS times before falling back' do
      provider = instance_double(BSV::Network::Provider, name: 'P1',
                                                         commands: Set.new([:get_tx]),
                                                         rate_limit: nil)
      retryable_error = error('rate limited', retryable: true)
      allow(provider).to receive(:call).with(:get_tx, any_args).and_return(retryable_error)
      services = described_class.new(providers: [provider])

      services.call(:get_tx, 'txid')

      expect(provider).to have_received(:call).exactly(BSV::Network::Services::RETRYABLE_ATTEMPTS).times
    end

    it 'returns immediately on a non-retryable response (no backoff sleep)' do
      provider = stub_provider('P1', { get_tx: error('bad request', retryable: false) })
      services = described_class.new(providers: [provider])
      allow(services).to receive(:backoff_sleep)

      services.call(:get_tx, 'txid')

      expect(services).not_to have_received(:backoff_sleep)
    end

    it 'falls back to the next provider after the first one exhausts its retries' do
      failing = instance_double(BSV::Network::Provider, name: 'P1',
                                                        commands: Set.new([:get_tx]),
                                                        rate_limit: nil)
      allow(failing).to receive(:call).with(:get_tx, any_args)
                                      .and_return(error('rate limited', retryable: true))
      working = stub_provider('P2', { get_tx: success('from_p2') })
      services = described_class.new(providers: [failing, working])

      result = services.call(:get_tx, 'txid')

      expect(result.http_success?).to be true
      expect(result.data).to eq('from_p2')
      expect(failing).to have_received(:call).exactly(BSV::Network::Services::RETRYABLE_ATTEMPTS).times
    end
  end

  # --- Normalization ---

  describe 'broadcast normalization' do
    it 'normalizes ARC-style response (symbol keys from escape hatch)' do
      provider = stub_provider('ARC', {
                                 broadcast: success({
                                                      txid: 'abc123',
                                                      tx_status: 'SEEN_ON_NETWORK',
                                                      block_hash: nil,
                                                      block_height: nil
                                                    })
                               })
      services = described_class.new(providers: [provider])

      result = services.call(:broadcast, 'rawtx')
      expect(result.data[:txid]).to eq('abc123')
      expect(result.data[:tx_status]).to eq('SEEN_ON_NETWORK')
      expect(result.data).to have_key(:block_hash)
      expect(result.data).to have_key(:competing_txs)
    end

    it 'normalizes WoC-style response (string keys, minimal fields)' do
      provider = stub_provider('WoC', {
                                 broadcast: success({ 'txid' => 'abc123' })
                               })
      services = described_class.new(providers: [provider])

      result = services.call(:broadcast, 'rawtx')
      expect(result.data[:txid]).to eq('abc123')
      expect(result.data[:tx_status]).to be_nil
      expect(result.data).to have_key(:block_height)
    end

    it 'normalizes ARC-style raw JSON (string camelCase keys)' do
      provider = stub_provider('ARC', {
                                 broadcast: success({
                                                      'txid' => 'abc',
                                                      'txStatus' => 'MINED',
                                                      'blockHeight' => 800_000,
                                                      'blockHash' => 'fff',
                                                      'competingTxs' => ['other']
                                                    })
                               })
      services = described_class.new(providers: [provider])

      result = services.call(:broadcast, 'rawtx')
      expect(result.data[:txid]).to eq('abc')
      expect(result.data[:tx_status]).to eq('MINED')
      expect(result.data[:block_height]).to eq(800_000)
      expect(result.data[:competing_txs]).to eq(['other'])
    end
  end

  describe 'tx_status normalization' do
    it 'normalizes to canonical form' do
      provider = stub_provider('ARC', {
                                 get_tx_status: success({
                                                          'txid' => 'abc',
                                                          'txStatus' => 'MINED',
                                                          'blockHeight' => 800_000
                                                        })
                               })
      services = described_class.new(providers: [provider])

      result = services.call(:get_tx_status, txid: 'abc')
      expect(result.data[:tx_status]).to eq('MINED')
      expect(result.data[:block_height]).to eq(800_000)
    end
  end

  describe 'get_tx normalization' do
    it 'passes through hex strings unchanged' do
      provider = stub_provider('WoC', { get_tx: success('deadbeef') })
      services = described_class.new(providers: [provider])

      result = services.call(:get_tx, 'txid')
      expect(result.data).to eq('deadbeef')
    end

    it 'decodes JungleBus base64 transaction to hex' do
      tx_binary = "\xde\xad\xbe\xef".b
      tx_b64 = Base64.strict_encode64(tx_binary)
      provider = stub_provider('GP', {
                                 get_tx: success({ 'transaction' => tx_b64, 'merkle_proof' => '', 'block_height' => nil })
                               })
      services = described_class.new(providers: [provider])

      result = services.call(:get_tx, 'txid')
      expect(result.data).to eq('deadbeef')
    end
  end

  # --- Sibling memo ---

  describe 'sibling memo' do
    let(:tx_b64) { Base64.strict_encode64("\xde\xad".b) }
    let(:proof_b64) { Base64.strict_encode64("\xca\xfe".b) }

    it 'stashes JungleBus proof and serves it on get_merkle_path' do
      provider = stub_provider('GP', {
                                 get_tx: success({ 'transaction' => tx_b64, 'merkle_proof' => proof_b64, 'block_height' => 800_000 })
                               })
      services = described_class.new(providers: [provider])

      services.call(:get_tx, 'abc123')

      result = services.call(:get_merkle_path, txid: 'abc123')
      expect(result.http_success?).to be true
      expect(result.data).to eq(proof_b64)
    end

    it 'is one-shot — consumed after first read' do
      provider = stub_provider('GP', {
                                 get_tx: success({ 'transaction' => tx_b64, 'merkle_proof' => proof_b64, 'block_height' => 800_000 }),
                                 get_merkle_path: error('no provider', retryable: false)
                               })
      services = described_class.new(providers: [provider])

      services.call(:get_tx, 'abc123')
      services.call(:get_merkle_path, txid: 'abc123')

      result = services.call(:get_merkle_path, txid: 'abc123')
      expect(result.http_success?).to be false
    end

    it 'expires after TTL' do
      provider = stub_provider('GP', {
                                 get_tx: success({ 'transaction' => tx_b64, 'merkle_proof' => proof_b64, 'block_height' => 800_000 }),
                                 get_merkle_path: error('no provider', retryable: false)
                               })
      services = described_class.new(providers: [provider])

      services.call(:get_tx, 'abc123')
      services.instance_variable_get(:@sibling_memo)['abc123'][:stashed_at] = Time.now - 10

      result = services.call(:get_merkle_path, txid: 'abc123')
      expect(result.http_success?).to be false
    end

    it 'does not stash when merkle_proof is empty' do
      provider = stub_provider('GP', {
                                 get_tx: success({ 'transaction' => tx_b64, 'merkle_proof' => '', 'block_height' => nil }),
                                 get_merkle_path: error('no provider', retryable: false)
                               })
      services = described_class.new(providers: [provider])

      services.call(:get_tx, 'abc123')
      result = services.call(:get_merkle_path, txid: 'abc123')
      expect(result.http_success?).to be false
    end
  end

  # --- Broadcast affinity ---

  describe 'broadcast affinity' do
    it 'prefers the broadcast provider for get_tx_status' do
      arc = stub_provider('ARC', {
                            broadcast: success({ 'txid' => 'abc', 'txStatus' => 'SEEN_ON_NETWORK' }),
                            get_tx_status: success({ 'txid' => 'abc', 'txStatus' => 'MINED', 'blockHeight' => 800_000 })
                          })
      woc = stub_provider('WoC', {
                            get_tx_status: success({ 'txid' => 'abc', 'txStatus' => 'UNKNOWN' })
                          })

      services = described_class.new(providers: [woc, arc])
      services.call(:broadcast, 'rawtx')

      result = services.call(:get_tx_status, txid: 'abc')
      expect(result.data[:tx_status]).to eq('MINED')
    end
  end

  # --- Rate limiting ---

  describe 'rate limiting' do
    it 'creates token buckets for providers with rate_limit' do
      provider = stub_provider('WoC', { get_tx: success('deadbeef') }, rate_limit: 3)
      services = described_class.new(providers: [provider])

      buckets = services.instance_variable_get(:@buckets)
      expect(buckets[provider]).to be_a(BSV::Network::Services::TokenBucket)
    end

    it 'does not create token buckets for providers without rate_limit' do
      provider = stub_provider('WoC', { get_tx: success('deadbeef') }, rate_limit: nil)
      services = described_class.new(providers: [provider])

      buckets = services.instance_variable_get(:@buckets)
      expect(buckets[provider]).to be_nil
    end
  end

  # --- Accessors ---

  describe '#commands' do
    it 'returns union of all provider commands' do
      p1 = stub_provider('ARC', { broadcast: success({}) })
      p2 = stub_provider('WoC', { get_tx: success(''), get_utxos: success([]) })
      services = described_class.new(providers: [p1, p2])

      expect(services.commands).to eq(Set[:broadcast, :get_tx, :get_utxos])
    end
  end

  describe '#providers' do
    it 'returns the registered providers' do
      p1 = stub_provider('P1', { get_tx: success('') })
      services = described_class.new(providers: [p1])

      expect(services.providers).to eq([p1])
      expect(services.providers).to be_frozen
    end
  end

  # --- TokenBucket ---

  describe BSV::Network::Services::TokenBucket do
    it 'allows immediate acquisition when tokens are available' do
      bucket = described_class.new(10)
      start = Time.now
      bucket.acquire!
      elapsed = Time.now - start
      expect(elapsed).to be < 0.1
    end

    it 'rejects zero rate' do
      expect { described_class.new(0) }.to raise_error(ArgumentError, /positive/)
    end

    it 'rejects negative rate' do
      expect { described_class.new(-1) }.to raise_error(ArgumentError, /positive/)
    end
  end

  # --- push! ---

  describe '#push!' do
    let(:provider) do
      stub_provider('ARC', { broadcast: success({ 'txid' => 'abc', 'txStatus' => 'SEEN_ON_NETWORK' }) })
    end
    let(:services) { described_class.new(providers: [provider]) }

    def pushable_entity(command: :broadcast, payload: 'rawtx_bytes')
      double('PushableEntity',
             push_command: command,
             push_payload: payload,
             write!: nil)
    end

    it 'calls write! on success and returns the response' do
      entity = pushable_entity
      result = services.push!(entity)

      expect(entity).to have_received(:write!).with(result)
      expect(result.http_success?).to be true
      expect(result.data[:txid]).to eq('abc')
    end

    it 'does not call write! on failure and returns the error response' do
      failing = stub_provider('ARC', { broadcast: error('rejected') })
      svc = described_class.new(providers: [failing])
      entity = pushable_entity

      result = svc.push!(entity)

      expect(entity).not_to have_received(:write!)
      expect(result.http_success?).to be false
      expect(result.error_message).to eq('rejected')
    end

    it 'does not call write! on 404' do
      nf_provider = stub_provider('ARC', { broadcast: not_found })
      svc = described_class.new(providers: [nf_provider])
      entity = pushable_entity

      result = svc.push!(entity)

      expect(entity).not_to have_received(:write!)
      expect(result.http_not_found?).to be true
    end

    it 'lets write! exceptions propagate' do
      entity = pushable_entity
      allow(entity).to receive(:write!).and_raise(RuntimeError, 'DB error')

      expect { services.push!(entity) }.to raise_error(RuntimeError, 'DB error')
    end

    it 'routes through the correct provider' do
      result = services.push!(pushable_entity)
      expect(provider).to have_received(:call).with(:broadcast, 'rawtx_bytes')
      expect(result.data[:txid]).to eq('abc')
    end

    it 'returns the ProtocolResponse' do
      result = services.push!(pushable_entity)
      expect(result).to be_a(BSV::Network::ProtocolResponse)
    end
  end

  # --- fetch! ---

  describe '#fetch!' do
    let(:provider) do
      stub_provider('ARC', {
                      get_tx_status: success({ 'txid' => 'abc', 'txStatus' => 'MINED', 'blockHeight' => 800_000 })
                    })
    end
    let(:services) { described_class.new(providers: [provider]) }

    def fetchable_entity(command: :get_tx_status, args: { txid: 'abc' })
      double('FetchableEntity',
             fetch_command: command,
             fetch_args: args,
             write!: nil)
    end

    it 'calls write! on success and returns the response' do
      entity = fetchable_entity
      result = services.fetch!(entity)

      expect(entity).to have_received(:write!).with(result)
      expect(result.http_success?).to be true
      expect(result.data[:tx_status]).to eq('MINED')
    end

    it 'does not call write! on failure and returns the error response' do
      failing = stub_provider('ARC', { get_tx_status: error('server error') })
      svc = described_class.new(providers: [failing])
      entity = fetchable_entity

      result = svc.fetch!(entity)

      expect(entity).not_to have_received(:write!)
      expect(result.http_success?).to be false
    end

    it 'does not call write! on 404' do
      nf_provider = stub_provider('ARC', { get_tx_status: not_found })
      svc = described_class.new(providers: [nf_provider])
      entity = fetchable_entity

      result = svc.fetch!(entity)

      expect(entity).not_to have_received(:write!)
      expect(result.http_not_found?).to be true
    end

    it 'lets write! exceptions propagate' do
      entity = fetchable_entity
      allow(entity).to receive(:write!).and_raise(RuntimeError, 'DB error')

      expect { services.fetch!(entity) }.to raise_error(RuntimeError, 'DB error')
    end

    it 'passes keyword args through to call' do
      services.fetch!(fetchable_entity(args: { txid: 'abc' }))
      expect(provider).to have_received(:call).with(:get_tx_status, txid: 'abc')
    end

    it 'returns the ProtocolResponse' do
      result = services.fetch!(fetchable_entity)
      expect(result).to be_a(BSV::Network::ProtocolResponse)
    end
  end
end
