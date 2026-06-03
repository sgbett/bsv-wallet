# frozen_string_literal: true

require 'net/http'
require_relative '../wallet/store/shared_context'

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

    it 'forwards callback_token: as a kwarg so the underlying ARC/Arcade protocol sets X-CallbackToken' do
      provider = stub_provider('ARC', { broadcast: success({ 'txid' => 'abc' }) })
      broadcaster = described_class.new(providers: [provider])

      broadcaster.broadcast('rawtx', wtxid: wtxid, callback_token: 'tok-abc123')

      # The SDK ARC/Arcade protocols both accept callback_token: as a
      # per-call kwarg and set it as X-CallbackToken on the POST. Asserting
      # at the Provider#call boundary catches the wiring without needing a
      # full HTTP fixture; the SDK already specs the header-setting end.
      expect(provider).to have_received(:call).with(:broadcast, 'rawtx', callback_token: 'tok-abc123')
    end

    it 'omits callback_token: from the kwargs when not supplied (lenient default)' do
      provider = stub_provider('ARC', { broadcast: success({ 'txid' => 'abc' }) })
      broadcaster = described_class.new(providers: [provider])

      broadcaster.broadcast('rawtx', wtxid: wtxid)

      expect(provider).to have_received(:call).with(:broadcast, 'rawtx')
    end
  end

  describe '#provider_for' do
    it 'returns nil when no store is configured' do
      provider = stub_provider('ARC', { broadcast: success({ 'txid' => 'abc' }) })
      broadcaster = described_class.new(providers: [provider])

      expect(broadcaster.provider_for(wtxid)).to be_nil
    end

    it 'raises on an invalid wtxid' do
      provider = stub_provider('ARC', { broadcast: success({ 'txid' => 'abc' }) })
      broadcaster = described_class.new(providers: [provider])

      expect { broadcaster.provider_for('not bytes') }.to raise_error(ArgumentError, /wtxid/)
    end
  end

  describe '#get_tx_status' do
    let(:dtxid) { wtxid.reverse.unpack1('H*') }
    let(:status_data) { { 'txid' => dtxid, 'txStatus' => 'SEEN_ON_NETWORK', 'status' => 200 } }

    it 'returns the underlying ProtocolResponse (normalised)' do
      provider = stub_provider('ARC', { get_tx_status: success(status_data) })
      broadcaster = described_class.new(providers: [provider])

      response = broadcaster.get_tx_status(wtxid: wtxid, dtxid: dtxid)

      expect(response).to be_a(BSV::Network::ProtocolResponse)
      expect(response.http_success?).to be true
      expect(response.data[:tx_status]).to eq('SEEN_ON_NETWORK')
    end

    it 'forwards the dtxid via the +txid:+ kwarg (BRC-100 spec naming)' do
      provider = stub_provider('ARC', { get_tx_status: success(status_data) })
      broadcaster = described_class.new(providers: [provider])

      broadcaster.get_tx_status(wtxid: wtxid, dtxid: dtxid)

      expect(provider).to have_received(:call).with(:get_tx_status, txid: dtxid)
    end

    it 'falls back to the next provider on retryable error' do
      failing = stub_provider('P1', { get_tx_status: error('rate limited', retryable: true) })
      working = stub_provider('P2', { get_tx_status: success(status_data) })
      broadcaster = described_class.new(providers: [failing, working])

      response = broadcaster.get_tx_status(wtxid: wtxid, dtxid: dtxid)

      expect(response.http_success?).to be true
      expect(response.data[:tx_status]).to eq('SEEN_ON_NETWORK')
    end

    it 'returns a synthetic no-provider response when no provider serves :get_tx_status' do
      provider = stub_provider('BroadcastOnly', { broadcast: success({ 'txid' => 'abc' }) })
      broadcaster = described_class.new(providers: [provider])

      response = broadcaster.get_tx_status(wtxid: wtxid, dtxid: dtxid)

      expect(response.http_success?).to be false
      expect(response.error_message).to match(/no provider/)
    end

    it 'requires a valid wtxid' do
      provider = stub_provider('ARC', { get_tx_status: success(status_data) })
      broadcaster = described_class.new(providers: [provider])

      expect { broadcaster.get_tx_status(wtxid: 'not bytes', dtxid: dtxid) }
        .to raise_error(ArgumentError, /wtxid/)
    end
  end

  describe 'affinity persistence', :store do
    let(:gp) { stub_provider('GorillaPool', { broadcast: success({ 'txid' => 'abc', 'txStatus' => 'SEEN_ON_NETWORK' }) }) }
    let(:taal) { stub_provider('TAAL', { broadcast: success({ 'txid' => 'xyz', 'txStatus' => 'SEEN_ON_NETWORK' }) }) }
    let(:woc) { stub_provider('WhatsOnChain', { get_tx: success('deadbeef') }) }

    def insert_signed_action(wtxid:)
      BSV::Wallet::Store::Models::Action.create(
        outgoing: true, description: 'test action', nlocktime: 0,
        wtxid: Sequel.blob(wtxid),
        raw_tx: SecureRandom.random_bytes(100)
      ).tap do |action|
        BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')
      end
    end

    describe '#broadcast' do
      let(:bound_wtxid) { SecureRandom.random_bytes(32) }

      before { insert_signed_action(wtxid: bound_wtxid) }

      it 'persists the responding provider name onto broadcasts.provider' do
        broadcaster = described_class.new(providers: [gp, taal], store: store)

        broadcaster.broadcast('rawtx', wtxid: bound_wtxid)

        action_id = BSV::Wallet::Store::Models::Action.where(wtxid: Sequel.blob(bound_wtxid)).get(:id)
        expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: action_id).provider).to eq('GorillaPool')
      end

      it 'persists provider on an Arcade-shaped submit success (no txid in response)' do
        arcade = stub_provider('GorillaPool', { broadcast: success({ 'status' => 'submitted' }) })
        broadcaster = described_class.new(providers: [arcade], store: store)

        result = broadcaster.broadcast('rawtx', wtxid: bound_wtxid)

        expect(result.http_success?).to be true
        expect(result.data[:txid]).to be_nil
        action_id = BSV::Wallet::Store::Models::Action.where(wtxid: Sequel.blob(bound_wtxid)).get(:id)
        expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: action_id).provider).to eq('GorillaPool')
      end

      it 'does not persist provider on a failed broadcast' do
        failing = stub_provider('GorillaPool', { broadcast: error('boom') })
        broadcaster = described_class.new(providers: [failing], store: store)

        broadcaster.broadcast('rawtx', wtxid: bound_wtxid)

        action_id = BSV::Wallet::Store::Models::Action.where(wtxid: Sequel.blob(bound_wtxid)).get(:id)
        expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: action_id).provider).to be_nil
      end

      it 'overwrites a prior affinity on a second successful broadcast (last-broadcaster wins)' do
        described_class.new(providers: [taal], store: store).broadcast('rawtx', wtxid: bound_wtxid)
        described_class.new(providers: [gp], store: store).broadcast('rawtx', wtxid: bound_wtxid)

        action_id = BSV::Wallet::Store::Models::Action.where(wtxid: Sequel.blob(bound_wtxid)).get(:id)
        expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: action_id).provider).to eq('GorillaPool')
      end

      it 'tolerates a missing action row (race: action deleted post-submit)' do
        unbound = SecureRandom.random_bytes(32)
        broadcaster = described_class.new(providers: [gp], store: store)

        expect { broadcaster.broadcast('rawtx', wtxid: unbound) }.not_to raise_error
      end

      it 'raises on an invalid wtxid kwarg (boundary check)' do
        broadcaster = described_class.new(providers: [gp], store: store)

        expect { broadcaster.broadcast('rawtx', wtxid: 'not bytes') }
          .to raise_error(ArgumentError, /wtxid/)
      end

      # Affinity write is best-effort: the tx is already in the mempool by the
      # time the block runs. A DB failure must NOT propagate as if the broadcast
      # itself had failed — the poll loop recovers tx_status on the next pass,
      # only the routing hint is lost.
      it 'returns the successful response and warns (does not raise) when the affinity write fails' do
        failing_store = instance_double(BSV::Wallet::Store)
        allow(failing_store).to receive(:broadcast_provider_for).and_return(nil)
        allow(failing_store).to receive(:record_broadcast_provider)
          .and_raise(Sequel::DatabaseError.new('connection lost'))

        logger = double('Logger').as_null_object # accepts other log levels emitted along the call path
        allow(BSV).to receive(:logger).and_return(logger)

        broadcaster = described_class.new(providers: [gp], store: failing_store)

        result = broadcaster.broadcast('rawtx', wtxid: bound_wtxid)

        expect(result.http_success?).to be true
        expect(result.data[:txid]).to eq('abc')
        expect(logger).to have_received(:warn)
      end
    end

    describe '#provider_for' do
      let(:bound_wtxid) { SecureRandom.random_bytes(32) }

      before { insert_signed_action(wtxid: bound_wtxid) }

      it 'returns the Provider matching the persisted name after a successful broadcast' do
        broadcaster = described_class.new(providers: [gp, taal], store: store)
        broadcaster.broadcast('rawtx', wtxid: bound_wtxid)

        expect(broadcaster.provider_for(bound_wtxid)).to equal(gp)
      end

      it 'returns nil when the persisted name is not present in @providers (config drift)' do
        described_class.new(providers: [gp], store: store).broadcast('rawtx', wtxid: bound_wtxid)

        fresh = described_class.new(providers: [taal], store: store)
        expect(fresh.provider_for(bound_wtxid)).to be_nil
      end

      it 'returns nil when no affinity has been recorded for this wtxid' do
        broadcaster = described_class.new(providers: [gp, taal], store: store)

        expect(broadcaster.provider_for(bound_wtxid)).to be_nil
      end

      # Central acceptance: affinity survives daemon restart.
      it 'survives broadcaster reconstruction (simulated daemon restart)' do
        broadcaster_a = described_class.new(providers: [gp, taal], store: store)
        broadcaster_a.broadcast('rawtx', wtxid: bound_wtxid)

        broadcaster_b = described_class.new(providers: [gp, taal], store: store)
        expect(broadcaster_b.provider_for(bound_wtxid)).to equal(gp)
      end
    end

    describe 'affinity-aware selection' do
      let(:bound_wtxid) { SecureRandom.random_bytes(32) }

      before { insert_signed_action(wtxid: bound_wtxid) }

      it 'moves the affinity-preferred provider to the front of the candidate list' do
        # First broadcast records TAAL as the affined provider.
        described_class.new(providers: [taal], store: store).broadcast('rawtx', wtxid: bound_wtxid)

        # On the next call, TAAL is later in the priority list -- affinity must
        # pull it to the front so it's tried first.
        broadcaster = described_class.new(providers: [gp, taal], store: store)
        broadcaster.broadcast('rawtx', wtxid: bound_wtxid)

        expect(taal).to have_received(:call).with(:broadcast, 'rawtx').at_least(:once)
        expect(gp).not_to have_received(:call).with(:broadcast, 'rawtx')
      end

      it 'falls through to first-capable when the affinity provider is no longer registered' do
        described_class.new(providers: [stub_provider('GoneProvider', { broadcast: success({ 'txid' => 'a' }) })],
                            store: store).broadcast('rawtx', wtxid: bound_wtxid)

        broadcaster = described_class.new(providers: [gp, taal], store: store)
        broadcaster.broadcast('rawtx', wtxid: bound_wtxid)

        expect(gp).to have_received(:call).with(:broadcast, 'rawtx')
      end
    end

    describe 'affinity-aware selection for #get_tx_status' do
      let(:bound_wtxid) { SecureRandom.random_bytes(32) }
      let(:bound_dtxid) { bound_wtxid.reverse.unpack1('H*') }
      let(:status_data) { { 'txid' => bound_dtxid, 'txStatus' => 'SEEN_ON_NETWORK', 'status' => 200 } }

      # Both providers serve broadcast (so affinity can record on them) AND
      # get_tx_status (so the routing overlay has a candidate to reorder).
      let(:gp_status) do
        stub_provider('GorillaPool', {
                        broadcast: success({ 'txid' => bound_dtxid, 'txStatus' => 'SEEN_ON_NETWORK' }),
                        get_tx_status: success(status_data)
                      })
      end
      let(:taal_status) do
        stub_provider('TAAL', {
                        broadcast: success({ 'txid' => bound_dtxid, 'txStatus' => 'SEEN_ON_NETWORK' }),
                        get_tx_status: success(status_data)
                      })
      end

      before { insert_signed_action(wtxid: bound_wtxid) }

      it 'sends the get_tx_status query to the recorded provider first' do
        # Record TAAL as the affined provider via a prior broadcast.
        described_class.new(providers: [taal_status], store: store).broadcast('rawtx', wtxid: bound_wtxid)

        # GP is first in priority order, but affinity must pull TAAL forward.
        broadcaster = described_class.new(providers: [gp_status, taal_status], store: store)
        broadcaster.get_tx_status(wtxid: bound_wtxid, dtxid: bound_dtxid)

        expect(taal_status).to have_received(:call).with(:get_tx_status, txid: bound_dtxid)
        expect(gp_status).not_to have_received(:call).with(:get_tx_status, txid: bound_dtxid)
      end

      it 'falls through to first-capable when no affinity has been recorded' do
        broadcaster = described_class.new(providers: [gp_status, taal_status], store: store)
        broadcaster.get_tx_status(wtxid: bound_wtxid, dtxid: bound_dtxid)

        expect(gp_status).to have_received(:call).with(:get_tx_status, txid: bound_dtxid)
        expect(taal_status).not_to have_received(:call).with(:get_tx_status, txid: bound_dtxid)
      end

      it 'falls through to first-capable when the recorded provider is no longer registered (config drift)' do
        # Record a provider that won't be in @providers on the next boot.
        gone = stub_provider('GoneProvider', { broadcast: success({ 'txid' => bound_dtxid }) })
        described_class.new(providers: [gone], store: store).broadcast('rawtx', wtxid: bound_wtxid)

        broadcaster = described_class.new(providers: [gp_status, taal_status], store: store)
        broadcaster.get_tx_status(wtxid: bound_wtxid, dtxid: bound_dtxid)

        expect(gp_status).to have_received(:call).with(:get_tx_status, txid: bound_dtxid)
      end
    end
  end
end
