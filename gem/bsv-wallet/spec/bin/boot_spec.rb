# frozen_string_literal: true

# CLI.boot smoke specs — verify the boot path works end-to-end against
# the default SQLite store with no network dependencies.
#
# The end-to-end boot test runs in a subprocess to keep Sequel::Model.db
# from leaking into the parent spec process.

require 'open3'
require 'tmpdir'
require 'bsv/wallet/cli'

RSpec.describe BSV::Wallet::CLI do
  describe '.boot' do
    it 'constructs an Engine against the default SQLite store' do
      Dir.mktmpdir do |dir|
        db_path = File.join(dir, 'smoke.db')
        wif = BSV::Primitives::PrivateKey.generate.to_wif

        ruby_src = <<~RUBY
          $LOAD_PATH.unshift(#{File.expand_path('../../lib', __dir__).inspect})
          require 'bsv-wallet'
          require 'bsv/wallet/cli'
          ctx = BSV::Wallet::CLI.boot
          raise 'engine missing' unless ctx[:engine].is_a?(BSV::Wallet::Engine)
          store_klass = ctx[:engine].instance_variable_get(:@store).class
          raise "wrong store class \#{store_klass}" unless store_klass == BSV::Wallet::Store::SQLite
          # #266: CLI.boot derives callback_token from WIF and returns it
          # alongside the engine; walletd reads it from here to wire the
          # SSE listener.
          token = ctx[:callback_token]
          raise "callback_token shape: \#{token.inspect}" unless token.is_a?(String) && token.match?(/\\A[0-9a-f]{32}\\z/)
          puts 'ok'
        RUBY

        env = {
          'WIF' => wif,
          'DATABASE_URL' => "sqlite://#{db_path}"
        }
        stdout, stderr, status = Open3.capture3(env, 'ruby', '-e', ruby_src)

        expect(status.exitstatus).to eq(0), "stderr:\n#{stderr}\nstdout:\n#{stdout}"
        expect(stdout).to include('ok')
        expect(File).to exist(db_path)
      end
    end
  end

  # Chain-validity trust model selection (HLR #335). cli.rb:124 is the
  # single tracker-construction seam; assert the boot path wires the right
  # tracker for each +trust_model+. Subprocess-isolated like the smoke test
  # above (keeps Sequel::Model.db out of the parent process).
  describe '.boot trust_model selection (#335)' do
    def boot_and_report_tracker(env)
      Dir.mktmpdir do |dir|
        db_path = File.join(dir, 'trust.db')
        wif = BSV::Primitives::PrivateKey.generate.to_wif

        ruby_src = <<~RUBY
          $LOAD_PATH.unshift(#{File.expand_path('../../lib', __dir__).inspect})
          require 'bsv-wallet'
          require 'bsv/wallet/cli'
          ctx = BSV::Wallet::CLI.boot
          puts ctx[:engine].chain_tracker.class.name
        RUBY

        full_env = { 'WIF' => wif, 'DATABASE_URL' => "sqlite://#{db_path}" }.merge(env)
        stdout, stderr, status = Open3.capture3(full_env, 'ruby', '-e', ruby_src)
        raise "boot failed:\n#{stderr}\n#{stdout}" unless status.exitstatus.zero?

        stdout.strip
      end
    end

    it 'selects ChainTracker by default (trusted_service) — behaviour unchanged' do
      expect(boot_and_report_tracker('BSV_WALLET_TRUST_MODEL' => nil))
        .to eq('BSV::Network::ChainTracker')
    end

    it 'selects SpvHeaderChainTracker iff trust_model=spv_headers' do
      expect(boot_and_report_tracker('BSV_WALLET_TRUST_MODEL' => 'spv_headers'))
        .to eq('BSV::Network::SpvHeaderChainTracker')
    end

    # A mistyped toggle (e.g. +spv_header+, missing the trailing s) must not
    # silently fall back to the trusted-service tracker — that would weaken
    # verification while the operator believes spv_headers is active. Boot
    # fails loud instead (Copilot review on #488).
    it 'fails loud on an unknown trust_model rather than silently downgrading' do
      Dir.mktmpdir do |dir|
        db_path = File.join(dir, 'trust.db')
        wif = BSV::Primitives::PrivateKey.generate.to_wif
        ruby_src = <<~RUBY
          $LOAD_PATH.unshift(#{File.expand_path('../../lib', __dir__).inspect})
          require 'bsv-wallet'
          require 'bsv/wallet/cli'
          BSV::Wallet::CLI.boot
        RUBY
        env = { 'WIF' => wif, 'DATABASE_URL' => "sqlite://#{db_path}",
                'BSV_WALLET_TRUST_MODEL' => 'spv_header' }
        _stdout, stderr, status = Open3.capture3(env, 'ruby', '-e', ruby_src)

        expect(status.exitstatus).not_to eq(0)
        expect(stderr).to match(/unknown trust_model/i)
      end
    end
  end

  # Per-wallet Postgres derivation moved to BSV::Wallet::Fixtures (#292).
  # See spec/bsv/wallet/fixtures_spec.rb.

  describe '.default_sqlite_url' do
    it 'produces a wallet-name-aware SQLite path' do
      url = described_class.default_sqlite_url('alice')
      expect(url).to start_with('sqlite://')
      expect(url).to end_with('/alice.db')
    end

    it 'uses "default" suffix when wallet_name is nil' do
      expect(described_class.default_sqlite_url(nil)).to end_with('/default.db')
    end
  end
end
