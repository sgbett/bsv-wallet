# frozen_string_literal: true

require 'bsv-wallet'
require 'sequel'
require 'bsv/wallet/cli'
require 'bsv/wallet/fixtures/rebuilder'

# Unit specs for the +fixtures:*+ orchestration. Stubs the CLI
# boot + the admin Sequel connection so the suite runs without a live
# Postgres or chain provider.
RSpec.describe BSV::Wallet::Fixtures::Rebuilder do
  subject(:rebuilder) { described_class.new(registry: registry, out: out, fund_sats: 1_000_000) }

  let(:registry) do
    r = BSV::Wallet::Fixtures::Registry.new
    r.postgres_base = 'postgres://postgres:postgres@localhost:5433/'
    r.wallet :sdk,   wif: 'L_sdk'
    r.wallet :alice, wif: 'L_alice'
    r.wallet :bob,   wif: 'L_bob'
    r.wallet :test
    r
  end

  let(:out) { StringIO.new }
  # Shared scaffolding: replace +CLI.boot+ with a stub that returns a
  # per-wallet context hash, and short-circuit +Sequel.connect+ (used
  # for the admin connection that issues +DROP/CREATE DATABASE+).
  let(:contexts) { {} }
  let(:admin_db) { instance_double(Sequel::Database, run: nil, disconnect: nil) }

  before do
    allow(BSV::Wallet::CLI).to receive(:boot) { |wallet_name:| contexts.fetch(wallet_name.to_sym) }
    allow(Sequel).to receive(:connect).and_return(admin_db)
  end

  def stub_wallet_ctx(name, identity_key_bytes: "\x00".b * 33, root_address: "1#{name}root",
                      spendable_count: 0, root_utxos: [{ 'value' => 1_000_000 }])
    identity_pubkey_hash = BSV::Primitives::Digest.hash160(identity_key_bytes)
    key_deriver = instance_double(BSV::Wallet::KeyDeriver,
                                  identity_key_bytes: identity_key_bytes,
                                  identity_pubkey_hash: identity_pubkey_hash)
    public_key = instance_double(BSV::Primitives::PublicKey, address: root_address)
    private_key = instance_double(BSV::Primitives::PrivateKey, public_key: public_key)
    allow(key_deriver).to receive(:root_private_key).and_return(private_key)

    sweep_result = { sweep: nil, consolidation_steps: 0 }
    build_action_result = { wtxid: ("\x00".b * 32) }
    engine = instance_double(
      BSV::Wallet::Engine,
      sweep_to_root: sweep_result,
      build_action: build_action_result
    )
    # Network provider stub for the verify probe. Tests can override
    # http_success?/data via the +root_utxos+ kwarg.
    response = if root_utxos.nil?
                 instance_double(BSV::Network::ProtocolResponse,
                                 http_not_found?: true, http_success?: false, data: nil)
               else
                 instance_double(BSV::Network::ProtocolResponse,
                                 http_not_found?: false, http_success?: true, data: root_utxos)
               end
    # +Provider+ is a richly-built SDK runtime object — a plain double
    # avoids dragging its construction graph in just to verify two methods.
    provider = double('NetworkProvider')
    allow(provider).to receive(:call).with(:get_utxos, root_address).and_return(response)
    engine.instance_variable_set(:@network_provider, provider)

    utxo_pool = instance_double(BSV::Wallet::Store::UTXOPool, spendable_count: spendable_count)

    contexts[name.to_sym] = {
      engine: engine,
      utxo_pool: utxo_pool,
      key_deriver: key_deriver,
      db: instance_double(Sequel::Database)
    }
  end

  describe '#rebuild' do
    before do
      stub_wallet_ctx(:alice)
      stub_wallet_ctx(:sdk)
    end

    it 'sweeps, drops, creates, and migrates in order — no funding' do
      drop_call = nil
      create_call = nil
      allow(admin_db).to receive(:run) do |sql|
        drop_call ||= sql if sql.include?('DROP DATABASE')
        create_call ||= sql if sql.include?('CREATE DATABASE')
      end

      rebuilder.rebuild(:alice)

      expect(drop_call).to eq('DROP DATABASE IF EXISTS "bsv_wallet_alice" WITH (FORCE)')
      expect(create_call).to eq('CREATE DATABASE "bsv_wallet_alice"')
      expect(contexts[:alice][:engine]).to have_received(:sweep_to_root)
      # +rebuild+ does not move funds — that is +fund+'s job.
      expect(contexts[:sdk][:engine]).not_to have_received(:build_action)
    end

    it 'raises when the wallet is not in the registry' do
      expect { rebuilder.rebuild(:never) }.to raise_error(ArgumentError, /:never is not registered/)
    end

    it 'aborts when sweep raises (no drop, no create)' do
      allow(contexts[:alice][:engine]).to receive(:sweep_to_root).and_raise(StandardError, 'cannot sign')

      expect { rebuilder.rebuild(:alice) }.to raise_error(StandardError, 'cannot sign')
      expect(admin_db).not_to have_received(:run)
    end

    it 'proceeds when the wallet has nothing to sweep' do
      # sweep_to_root returns { sweep: nil } when the spendable pool
      # is empty — soft signal, not an error. Drop+create+migrate still
      # run.
      allow(contexts[:alice][:engine]).to receive(:sweep_to_root)
        .and_return(sweep: nil, consolidation_steps: 0)

      expect { rebuilder.rebuild(:alice) }.not_to raise_error
      expect(admin_db).to have_received(:run).at_least(:twice)
      expect(out.string).to include('sweep: alice: nothing to sweep')
    end

    it 'routes DROP/CREATE through the postgres admin DB, not the target' do
      rebuilder.rebuild(:alice)

      expect(Sequel).to have_received(:connect).with('postgres://postgres:postgres@localhost:5433/postgres').at_least(:once)
    end

    it 'treats :sdk like any other wallet (no special dispatch, no fund)' do
      rebuilder.rebuild(:sdk)

      expect(contexts[:sdk][:engine]).to have_received(:sweep_to_root)
      expect(contexts[:sdk][:engine]).not_to have_received(:build_action)
    end
  end

  describe '#fund' do
    before do
      stub_wallet_ctx(:alice, identity_key_bytes: ("\x02".b * 33))
      stub_wallet_ctx(:sdk)
    end

    it 'sends sats from :sdk to the target root P2PKH at the default amount' do
      rebuilder.fund(:alice)

      expect(contexts[:sdk][:engine]).to have_received(:build_action) do |args|
        expect(args[:outputs].first[:satoshis]).to eq(1_000_000)
        expect(args[:outputs].first[:spendable_intent]).to eq('none')
      end
    end

    it 'honours an explicit sats override' do
      rebuilder.fund(:alice, sats: 250_000)

      expect(contexts[:sdk][:engine]).to have_received(:build_action) do |args|
        expect(args[:outputs].first[:satoshis]).to eq(250_000)
      end
    end

    it 'rejects :sdk (cannot fund the funder from itself)' do
      expect { rebuilder.fund(:sdk) }
        .to raise_error(ArgumentError, /:sdk is the funder and cannot fund itself/)
      expect(contexts[:sdk][:engine]).not_to have_received(:build_action)
    end

    it 'raises when the wallet is not in the registry' do
      expect { rebuilder.fund(:never) }.to raise_error(ArgumentError, /:never is not registered/)
    end
  end

  # Dispatcher tests intentionally stub the orchestrator's own
  # +rebuild+ entry point to assert the per-wallet dispatch loop. The
  # unit under test here is +rebuild_all+'s iteration + skip-list
  # logic, not the per-wallet body — the latter is covered by the
  # +#rebuild+ block above.
  describe '#rebuild_all' do
    before do
      stub_wallet_ctx(:alice)
      stub_wallet_ctx(:bob)
      stub_wallet_ctx(:sdk)
    end

    it 'skips :test (no WIF)' do
      allow(rebuilder).to receive(:rebuild) # rubocop:disable RSpec/SubjectStub

      rebuilder.rebuild_all

      expect(rebuilder).not_to have_received(:rebuild).with(:test) # rubocop:disable RSpec/SubjectStub
    end

    it 'invokes rebuild on every non-skipped wallet, including :sdk' do
      allow(rebuilder).to receive(:rebuild) # rubocop:disable RSpec/SubjectStub

      rebuilder.rebuild_all

      expect(rebuilder).to have_received(:rebuild).with(:alice) # rubocop:disable RSpec/SubjectStub
      expect(rebuilder).to have_received(:rebuild).with(:bob)   # rubocop:disable RSpec/SubjectStub
      expect(rebuilder).to have_received(:rebuild).with(:sdk)   # rubocop:disable RSpec/SubjectStub
    end

    it 'skips registered wallets that carry no WIF (e.g. unconfigured w1..w5)' do
      registry.wallet :w1 # WIF intentionally absent
      allow(rebuilder).to receive(:rebuild) # rubocop:disable RSpec/SubjectStub

      rebuilder.rebuild_all

      expect(rebuilder).not_to have_received(:rebuild).with(:w1) # rubocop:disable RSpec/SubjectStub
    end
  end

  describe '#verify' do
    it 'returns an empty failures list when every wallet has zero spendable rows + non-zero root balance' do
      stub_wallet_ctx(:alice, spendable_count: 0, root_utxos: [{ 'value' => 1_000_000 }])
      stub_wallet_ctx(:bob,   spendable_count: 0, root_utxos: [{ 'value' => 500_000 }])
      stub_wallet_ctx(:sdk,   spendable_count: 0, root_utxos: [{ 'value' => 50_000_000 }])

      expect(rebuilder.verify).to eq([])
      expect(out.string).to include('verify: all wallets OK')
    end

    it 'returns a failure when a wallet has stale spendable rows' do
      stub_wallet_ctx(:alice, spendable_count: 3)
      stub_wallet_ctx(:bob,   spendable_count: 0, root_utxos: [{ 'value' => 1_000_000 }])
      stub_wallet_ctx(:sdk,   spendable_count: 0, root_utxos: [{ 'value' => 1_000_000 }])

      failures = rebuilder.verify
      expect(failures.map(&:first)).to contain_exactly(:alice)
      expect(out.string).to include('alice: FAIL — 3 stale spendable row(s)')
    end

    it 'returns a failure when a wallet has zero on-chain root balance' do
      stub_wallet_ctx(:alice, spendable_count: 0, root_utxos: [])
      stub_wallet_ctx(:bob,   spendable_count: 0, root_utxos: [{ 'value' => 1_000_000 }])
      stub_wallet_ctx(:sdk,   spendable_count: 0, root_utxos: [{ 'value' => 1_000_000 }])

      failures = rebuilder.verify
      expect(failures.map(&:first)).to contain_exactly(:alice)
      expect(out.string).to include('alice: FAIL — zero root balance')
    end

    it 'treats a 404 from the network provider as zero balance' do
      stub_wallet_ctx(:alice, spendable_count: 0, root_utxos: nil) # nil → http_not_found?
      stub_wallet_ctx(:bob,   spendable_count: 0, root_utxos: [{ 'value' => 1_000_000 }])
      stub_wallet_ctx(:sdk,   spendable_count: 0, root_utxos: [{ 'value' => 1_000_000 }])

      expect(rebuilder.verify.map(&:first)).to contain_exactly(:alice)
    end

    it 'skips :test (no WIF)' do
      stub_wallet_ctx(:alice, spendable_count: 0, root_utxos: [{ 'value' => 1 }])
      stub_wallet_ctx(:bob,   spendable_count: 0, root_utxos: [{ 'value' => 1 }])
      stub_wallet_ctx(:sdk,   spendable_count: 0, root_utxos: [{ 'value' => 1 }])

      rebuilder.verify

      expect(BSV::Wallet::CLI).not_to have_received(:boot).with(wallet_name: 'test')
    end
  end

  describe 'admin URL resolution' do
    it 'raises when postgres_base is unset on the registry' do
      empty = BSV::Wallet::Fixtures::Registry.new
      empty.wallet :alice, wif: 'L1'
      stub_wallet_ctx(:alice)
      stub_wallet_ctx(:sdk)

      rb = described_class.new(registry: empty, out: out)

      expect { rb.rebuild(:alice) }.to raise_error(ArgumentError, /postgres_base is not configured/)
    end
  end
end
