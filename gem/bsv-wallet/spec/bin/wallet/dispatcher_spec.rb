# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'bsv/wallet/cli/dispatcher'

RSpec.describe BSV::Wallet::CLI::Dispatcher do
  describe '.parse_global_options' do
    it 'parses --wallet=<name>' do
      opts, remaining = described_class.parse_global_options(['--wallet=alice', 'balance'])
      expect(opts.wallet_name).to eq('alice')
      expect(remaining).to eq(['balance'])
    end

    it 'parses --network and converts to symbol' do
      opts, = described_class.parse_global_options(['--network=testnet', 'balance'])
      expect(opts.network).to eq(:testnet)
    end

    it 'treats --network= (blank) as nil so CLI.boot config fallback fires' do
      opts, = described_class.parse_global_options(['--network=', 'balance'])
      expect(opts.network).to be_nil
    end

    it 'treats --wallet= (blank) as nil so CLI.boot end-user mode fires' do
      opts, = described_class.parse_global_options(['--wallet=', 'balance'])
      expect(opts.wallet_name).to be_nil
    end

    it 'trims whitespace from --wallet' do
      opts, = described_class.parse_global_options(['--wallet= alice ', 'balance'])
      expect(opts.wallet_name).to eq('alice')
    end

    it 'trims whitespace from --network' do
      opts, = described_class.parse_global_options(['--network= mainnet ', 'balance'])
      expect(opts.network).to eq(:mainnet)
    end

    it 'parses --json' do
      opts, = described_class.parse_global_options(['--json', 'balance'])
      expect(opts.json).to be(true)
    end

    it 'leaves subcommand argv intact in remaining' do
      _, remaining = described_class.parse_global_options(
        ['--wallet=alice', 'list', 'outputs', '--limit=5']
      )
      expect(remaining).to eq(['list', 'outputs', '--limit=5'])
    end

    it 'returns empty remaining when no subcommand' do
      _, remaining = described_class.parse_global_options(['--wallet=alice'])
      expect(remaining).to eq([])
    end
  end

  describe 'secrets policy: --wif on TTY' do
    before { allow($stdin).to receive(:tty?).and_return(true) }

    it 'refuses --wif=<wif> on TTY without --allow-insecure-wif' do
      expect do
        described_class.parse_global_options(['--wif=L1xxx', 'balance'])
      end.to raise_error(BSV::Wallet::CLI::InsecureWifError, /shell-history capture/)
    end

    it 'allows --wif=<wif> on TTY when --allow-insecure-wif is set' do
      opts, = described_class.parse_global_options(
        ['--wif=L1xxx', '--allow-insecure-wif', 'balance']
      )
      expect(opts.wif_override).to eq('L1xxx')
    end
  end

  describe 'secrets policy: --wif on non-TTY (piped)' do
    before { allow($stdin).to receive(:tty?).and_return(false) }

    it 'accepts --wif=<wif> when stdin is piped' do
      opts, = described_class.parse_global_options(['--wif=L1xxx', 'balance'])
      expect(opts.wif_override).to eq('L1xxx')
    end
  end

  describe 'secrets policy: --wif-file' do
    let(:tmpdir) { Dir.mktmpdir }
    let(:wif_file) { File.join(tmpdir, 'wif') }
    let(:wif_value) { 'L1RrrnXkcKut5DEMwtDthjwRcTTwED36thyL1DebVrKuwvohjMNi' }

    before do
      File.write(wif_file, "#{wif_value}\n")
      File.chmod(0o600, wif_file)
    end

    after { FileUtils.rm_rf(tmpdir) }

    it 'reads the WIF from a mode-0600 file' do
      opts, = described_class.parse_global_options(
        ["--wif-file=#{wif_file}", 'balance']
      )
      expect(opts.wif_override).to eq(wif_value)
    end

    it 'refuses world-readable WIF files' do
      File.chmod(0o644, wif_file)
      expect do
        described_class.parse_global_options(["--wif-file=#{wif_file}", 'balance'])
      end.to raise_error(BSV::Wallet::CLI::UsageError, /mode must be 0600/)
    end
  end

  describe 'secrets policy: --database-url' do
    it 'accepts URLs without password in userinfo' do
      opts, = described_class.parse_global_options(
        ['--database-url=postgres://user@host/db', 'balance']
      )
      expect(opts.database_url_override).to eq('postgres://user@host/db')
    end

    it 'refuses URLs with password embedded in userinfo' do
      expect do
        described_class.parse_global_options(
          ['--database-url=postgres://user:pass@host/db', 'balance']
        )
      end.to raise_error(BSV::Wallet::CLI::UsageError, /embedded password refused/)
    end

    it 'reports an invalid URL as a usage error' do
      expect do
        described_class.parse_global_options(
          ['--database-url=not a url', 'balance']
        )
      end.to raise_error(BSV::Wallet::CLI::UsageError, /invalid URI/)
    end
  end

  describe 'secrets policy: --env=<file>' do
    let(:tmpdir) { Dir.mktmpdir }
    let(:env_file) { File.join(tmpdir, '.env') }

    before do
      File.write(env_file, "BSV_WALLET_POSTGRES=postgres://localhost/test\n")
      File.chmod(0o600, env_file)
    end

    after { FileUtils.rm_rf(tmpdir) }

    it 'loads keys with allowed prefixes' do
      ENV.delete('BSV_WALLET_POSTGRES')
      described_class.parse_global_options(["--env=#{env_file}", 'balance'])
      expect(ENV.fetch('BSV_WALLET_POSTGRES')).to eq('postgres://localhost/test')
    ensure
      ENV.delete('BSV_WALLET_POSTGRES')
    end

    it 'does not override existing process ENV (seed-mechanism)' do
      ENV['BSV_WALLET_POSTGRES'] = 'postgres://existing/db'
      described_class.parse_global_options(["--env=#{env_file}", 'balance'])
      expect(ENV.fetch('BSV_WALLET_POSTGRES')).to eq('postgres://existing/db')
    ensure
      ENV.delete('BSV_WALLET_POSTGRES')
    end

    it 'refuses world-readable env files' do
      File.chmod(0o644, env_file)
      expect do
        described_class.parse_global_options(["--env=#{env_file}", 'balance'])
      end.to raise_error(BSV::Wallet::CLI::UsageError, /mode must be 0600/)
    end

    it 'refuses symlinked env files without --env-allow-symlink' do
      Dir.mktmpdir do |dir2|
        symlink = File.join(dir2, 'env-link')
        File.symlink(env_file, symlink)
        expect do
          described_class.parse_global_options(["--env=#{symlink}", 'balance'])
        end.to raise_error(BSV::Wallet::CLI::UsageError, /symlinks refused/)
      end
    end
  end

  describe '.call' do
    it 'returns exit code 0 for --help' do
      code = nil
      expect { code = described_class.call(['--help']) }.to output(%r{Usage: bin/wallet}).to_stdout
      expect(code).to eq(0)
    end

    it 'returns exit code 2 for unknown command' do
      expect { described_class.call(['nonexistent-command']) }.to output(/unknown command/).to_stderr
    end

    it 'translates UsageError to exit code 2' do
      allow(described_class).to receive(:boot_engine).and_raise(BSV::Wallet::CLI::UsageError, 'bad usage')
      # Should not raise; should return 2.
      code = described_class.call(['--wallet=alice', 'balance'])
      expect(code).to eq(2)
    end

    it 'translates a BSV::Wallet::Error to exit code 1' do
      allow(described_class).to receive(:boot_engine).and_raise(BSV::Wallet::Error.new('engine down'))
      code = described_class.call(['--wallet=alice', 'balance'])
      expect(code).to eq(1)
    end

    it 'redacts secret values from exception messages bubbled to stderr' do
      allow(described_class).to receive(:boot_engine).and_raise(
        BSV::Wallet::CLI::UsageError, 'bad wif=L1RrrnXkcKut5DEMwtDthjwRcTTwED36thyL1DebVrKuwvohjMNi'
      )
      expect do
        described_class.call(['--wallet=alice', 'balance'])
      end.to output(/wif=\[REDACTED\]/).to_stderr
    end

    it 'redacts private_key values from exception messages' do
      allow(described_class).to receive(:boot_engine).and_raise(
        BSV::Wallet::CLI::UsageError, 'bad private_key: abc123def456'
      )
      expect do
        described_class.call(['--wallet=alice', 'balance'])
      end.to output(/private_key:\s*\[REDACTED\]/).to_stderr
    end

    it 'does NOT redact identity_key (interchange identifier, not secret)' do
      allow(described_class).to receive(:boot_engine).and_raise(
        BSV::Wallet::CLI::UsageError,
        "missing identity_key: 02#{'a' * 64}"
      )
      expect do
        described_class.call(['--wallet=alice', 'balance'])
      end.to output(/identity_key:\s*02a/).to_stderr
    end

    it 'does NOT redact public_key (interchange identifier)' do
      allow(described_class).to receive(:boot_engine).and_raise(
        BSV::Wallet::CLI::UsageError,
        'missing public_key: 02deadbeef'
      )
      expect do
        described_class.call(['--wallet=alice', 'balance'])
      end.to output(/public_key:\s*02deadbeef/).to_stderr
    end
  end
end
