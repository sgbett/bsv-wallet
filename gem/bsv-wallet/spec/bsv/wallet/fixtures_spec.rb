# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'bsv-wallet'

# Env mutation helper — saves the values for the named vars, runs
# the block, restores. Same pattern as config_spec.
unless defined?(with_env)
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
end

RSpec.describe BSV::Wallet::Fixtures do
  before { described_class.reset! }
  after  { described_class.reset! }

  describe '.configure / .wallet / .registry' do
    it 'registers a wallet with explicit WIF and database_url' do
      described_class.configure do |f|
        f.wallet :alice, wif: 'L1abc', database_url: 'sqlite://alice.db'
      end
      w = described_class.wallet(:alice)
      expect(w.name).to eq(:alice)
      expect(w.wif).to eq('L1abc')
      expect(w.database_url).to eq('sqlite://alice.db')
    end

    it 'derives database_url from postgres_base when not given' do
      described_class.configure do |f|
        f.postgres_base = 'postgres://localhost:5433/'
        f.wallet :alice, wif: 'L1abc'
      end
      expect(described_class.wallet(:alice).database_url)
        .to eq('postgres://localhost:5433/bsv_wallet_alice')
    end

    it 'tolerates postgres_base without a trailing slash' do
      described_class.configure do |f|
        f.postgres_base = 'postgres://localhost:5433'
        f.wallet :w1
      end
      expect(described_class.wallet(:w1).database_url)
        .to eq('postgres://localhost:5433/bsv_wallet_w1')
    end

    it 'returns nil database_url when no postgres_base and no explicit URL' do
      described_class.configure { |f| f.wallet :alice }
      expect(described_class.wallet(:alice).database_url).to be_nil
    end

    it 'returns nil for an unregistered wallet' do
      expect(described_class.wallet(:never)).to be_nil
    end

    it 'accepts string or symbol names for lookup' do
      described_class.configure { |f| f.wallet :alice, wif: 'L1' }
      expect(described_class.wallet('alice').wif).to eq('L1')
      expect(described_class.wallet(:alice).wif).to eq('L1')
    end

    it 'overwrites a re-registered wallet (last write wins)' do
      described_class.configure { |f| f.wallet :alice, wif: 'L1' }
      described_class.configure { |f| f.wallet :alice, wif: 'L2' }
      expect(described_class.wallet(:alice).wif).to eq('L2')
    end

    it '.configure yields the singleton Registry and returns it' do
      yielded = nil
      result = described_class.configure { |f| yielded = f }
      expect(yielded).to be(described_class.registry)
      expect(result).to be(described_class.registry)
    end
  end

  describe '.reset!' do
    it 'drops the singleton — next access instantiates fresh' do
      described_class.configure { |f| f.wallet :alice, wif: 'L1' }
      described_class.reset!
      expect(described_class.wallet(:alice)).to be_nil
    end
  end

  describe '.load_config_file!' do
    let(:tmpdir) { Dir.mktmpdir }

    around do |example|
      with_env('BSV_WALLET_FIXTURES' => nil, 'HOME' => tmpdir) { example.run }
    ensure
      FileUtils.rm_rf(tmpdir)
    end

    it 'falls back to the gem-default fixtures file when no user file exists' do
      # Gem-default registers :alice (et al) from ENV. With no WIF set,
      # the registration carries wif: nil but the wallet IS registered.
      with_env('BSV_WALLET_WIF_ALICE' => 'L1abc') do
        expect(described_class.load_config_file!).to eq(described_class::DEFAULT_FILE)
      end
      expect(described_class.wallet(:alice).wif).to eq('L1abc')
    end

    it 'evaluates the user override file and applies it' do
      path = File.join(tmpdir, 'fixtures.rb')
      File.write(path, "BSV::Wallet::Fixtures.configure { |f| f.wallet :custom, wif: 'L1' }\n")
      expect(described_class.load_config_file!(path)).to eq(path)
      expect(described_class.wallet(:custom).wif).to eq('L1')
    end

    it 'honours BSV_WALLET_FIXTURES env var' do
      path = File.join(tmpdir, 'custom-fixtures.rb')
      File.write(path, "BSV::Wallet::Fixtures.configure { |f| f.wallet :envpath, wif: 'X' }\n")
      with_env('BSV_WALLET_FIXTURES' => path) do
        described_class.load_config_file!
      end
      expect(described_class.wallet(:envpath).wif).to eq('X')
    end

    it 'propagates errors from a bad fixtures file' do
      path = File.join(tmpdir, 'bad.rb')
      File.write(path, "raise 'boom'\n")
      expect { described_class.load_config_file!(path) }.to raise_error(RuntimeError, 'boom')
    end
  end

  describe '.registry#names / #each' do
    it 'lists registered wallet names' do
      described_class.configure do |f|
        f.wallet :alice
        f.wallet :bob
      end
      expect(described_class.registry.names).to contain_exactly(:alice, :bob)
    end

    it '#each yields Wallet objects' do
      described_class.configure { |f| f.wallet :alice, wif: 'L1' }
      collected = described_class.registry.map { |w| w }
      expect(collected.size).to eq(1)
      expect(collected.first.name).to eq(:alice)
    end
  end
end
