# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'bsv-wallet'

# Env mutation helper — saves the values for the named vars, runs the
# block, restores. Pattern lifted from spec/bin/boot_spec.rb so this
# file stays consistent with the rest of the wallet spec suite (no
# new gem dependency for env stubbing).
def with_env(values)
  saved = values.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  begin
    values.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
    yield
  ensure
    saved.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
  end
end

RSpec.describe BSV::Wallet::Config do
  before { BSV::Wallet.reset_config! }
  after  { BSV::Wallet.reset_config! }

  describe '#initialize defaults read ENV' do
    it 'DATABASE_URL → database_url' do
      with_env('DATABASE_URL' => 'sqlite://example.db') do
        expect(described_class.new.database_url).to eq('sqlite://example.db')
      end
    end

    it 'WIF → wif' do
      with_env('WIF' => 'L1xyz') do
        expect(described_class.new.wif).to eq('L1xyz')
      end
    end

    it 'BSV_WALLET_NETWORK → network (symbol), defaults to :mainnet' do
      with_env('BSV_WALLET_NETWORK' => nil) do
        expect(described_class.new.network).to eq(:mainnet)
      end
      with_env('BSV_WALLET_NETWORK' => 'testnet') do
        expect(described_class.new.network).to eq(:testnet)
      end
    end

    it 'BSV_WALLET_NETWORK empty/whitespace → :mainnet (avoids the "".to_sym → :"" trap)' do
      with_env('BSV_WALLET_NETWORK' => '') do
        expect(described_class.new.network).to eq(:mainnet)
      end
      with_env('BSV_WALLET_NETWORK' => '   ') do
        expect(described_class.new.network).to eq(:mainnet)
      end
    end

    it 'BSV_WALLET_NETWORK strips surrounding whitespace' do
      with_env('BSV_WALLET_NETWORK' => '  testnet  ') do
        expect(described_class.new.network).to eq(:testnet)
      end
    end

    it 'LIMP_THRESHOLD → limp_threshold (Integer), default 50_000' do
      with_env('LIMP_THRESHOLD' => nil) do
        expect(described_class.new.limp_threshold).to eq(50_000)
      end
      with_env('LIMP_THRESHOLD' => '100000') do
        expect(described_class.new.limp_threshold).to eq(100_000)
      end
    end

    it 'raises on non-integer LIMP_THRESHOLD' do
      with_env('LIMP_THRESHOLD' => 'oops') do
        expect { described_class.new }.to raise_error(ArgumentError, /invalid value for Integer/)
      end
    end

    it 'BSV_WALLET_DAEMON_SEQUEL_CONNECTIONS → daemon_pool_size (Integer), default 16' do
      with_env('BSV_WALLET_DAEMON_SEQUEL_CONNECTIONS' => nil) do
        expect(described_class.new.daemon_pool_size).to eq(16)
      end
      with_env('BSV_WALLET_DAEMON_SEQUEL_CONNECTIONS' => '32') do
        expect(described_class.new.daemon_pool_size).to eq(32)
      end
    end

    it 'BSV_WALLET_TX_CACHE_SIZE → tx_cache_size (Integer), default 20000' do
      with_env('BSV_WALLET_TX_CACHE_SIZE' => nil) do
        expect(described_class.new.tx_cache_size).to eq(20_000)
      end
      with_env('BSV_WALLET_TX_CACHE_SIZE' => '500') do
        expect(described_class.new.tx_cache_size).to eq(500)
      end
    end

    it 'BSV_WALLET_FEE_RATE_SATS_PER_KB → fee_model (SatoshisPerKilobyte), default 100' do
      with_env('BSV_WALLET_FEE_RATE_SATS_PER_KB' => nil) do
        model = described_class.new.fee_model
        expect(model).to be_a(BSV::Transaction::FeeModels::SatoshisPerKilobyte)
        expect(model.value).to eq(100)
      end
      with_env('BSV_WALLET_FEE_RATE_SATS_PER_KB' => '250') do
        expect(described_class.new.fee_model.value).to eq(250)
      end
    end

    it 'BSV_WALLET_HINTS_SOCKET unset → hints_socket nil' do
      with_env('BSV_WALLET_HINTS_SOCKET' => nil) do
        expect(described_class.new.hints_socket).to be_nil
      end
    end

    it 'BSV_WALLET_HINTS_SOCKET empty → hints_socket nil' do
      with_env('BSV_WALLET_HINTS_SOCKET' => '') do
        expect(described_class.new.hints_socket).to be_nil
      end
    end

    it 'BSV_WALLET_HINTS_SOCKET whitespace-only → hints_socket nil' do
      with_env('BSV_WALLET_HINTS_SOCKET' => '   ') do
        expect(described_class.new.hints_socket).to be_nil
      end
    end

    it 'BSV_WALLET_HINTS_SOCKET real path → preserved' do
      with_env('BSV_WALLET_HINTS_SOCKET' => '/tmp/foo.sock') do
        expect(described_class.new.hints_socket).to eq('/tmp/foo.sock')
      end
    end

    it 'BSV_WALLET_TRUST_MODEL → trust_model (symbol), defaults to :trusted_service' do
      with_env('BSV_WALLET_TRUST_MODEL' => nil) do
        expect(described_class.new.trust_model).to eq(:trusted_service)
      end
      with_env('BSV_WALLET_TRUST_MODEL' => 'spv_headers') do
        expect(described_class.new.trust_model).to eq(:spv_headers)
      end
    end

    it 'spv_checkpoint defaults to nil (gem-baked checkpoint used unless overridden)' do
      expect(described_class.new.spv_checkpoint).to be_nil
    end
  end

  describe '.parse_trust_model' do
    it 'nil → :trusted_service (opt-in is the exception)' do
      expect(described_class.parse_trust_model(nil)).to eq(:trusted_service)
    end

    it 'blank / whitespace-only → :trusted_service (avoids the "".to_sym → :"" trap)' do
      expect(described_class.parse_trust_model('')).to eq(:trusted_service)
      expect(described_class.parse_trust_model('   ')).to eq(:trusted_service)
    end

    it '"spv_headers" → :spv_headers' do
      expect(described_class.parse_trust_model('spv_headers')).to eq(:spv_headers)
    end

    it 'strips surrounding whitespace' do
      expect(described_class.parse_trust_model('  spv_headers  ')).to eq(:spv_headers)
    end

    it 'passes a Symbol through' do
      expect(described_class.parse_trust_model(:spv_headers)).to eq(:spv_headers)
    end
  end

  describe 'BSV::Wallet module surface (config / configure / load_config_file!)' do
    describe '.config' do
      it 'returns a Config instance' do
        expect(BSV::Wallet.config).to be_a(described_class)
      end

      it 'returns the same singleton across calls' do
        first = BSV::Wallet.config
        expect(BSV::Wallet.config).to be(first)
      end
    end

    describe '.configure' do
      it 'yields the singleton Config and returns it' do
        yielded = nil
        result = BSV::Wallet.configure { |c| yielded = c }
        expect(yielded).to be(BSV::Wallet.config)
        expect(result).to be(BSV::Wallet.config)
      end

      it 'persists overrides on the singleton' do
        BSV::Wallet.configure { |c| c.limp_threshold = 123_456 }
        expect(BSV::Wallet.config.limp_threshold).to eq(123_456)
      end
    end

    describe '.reset_config!' do
      it 'drops the singleton so the next access reads fresh' do
        original = BSV::Wallet.config
        BSV::Wallet.reset_config!
        expect(BSV::Wallet.config).not_to be(original)
      end
    end

    describe '.load_config_file!' do
      let(:tmpdir) { Dir.mktmpdir }

      around do |example|
        with_env('BSV_WALLET_CONFIG' => nil, 'HOME' => tmpdir) { example.run }
      ensure
        FileUtils.rm_rf(tmpdir)
      end

      it 'is a no-op when the default file is absent' do
        expect(BSV::Wallet.load_config_file!).to be_nil
      end

      it 'evaluates the file and applies the configure block' do
        path = File.join(tmpdir, 'config.rb')
        File.write(path, "BSV::Wallet.configure { |c| c.limp_threshold = 777_777 }\n")

        expect(BSV::Wallet.load_config_file!(path)).to eq(path)
        expect(BSV::Wallet.config.limp_threshold).to eq(777_777)
      end

      it 'honours BSV_WALLET_CONFIG env var' do
        path = File.join(tmpdir, 'custom-config.rb')
        File.write(path, "BSV::Wallet.configure { |c| c.tx_cache_size = 42 }\n")

        with_env('BSV_WALLET_CONFIG' => path) do
          BSV::Wallet.load_config_file!
        end
        expect(BSV::Wallet.config.tx_cache_size).to eq(42)
      end

      it 'propagates errors from a bad config file (no silent swallow)' do
        path = File.join(tmpdir, 'bad.rb')
        File.write(path, "raise 'boom'\n")

        expect { BSV::Wallet.load_config_file!(path) }.to raise_error(RuntimeError, 'boom')
      end
    end
  end
end
