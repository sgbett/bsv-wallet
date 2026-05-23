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
