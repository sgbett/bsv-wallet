# frozen_string_literal: true

require 'open3'
require 'sequel'
require 'bsv-wallet'
require_relative 'wallet_derivation'

module E2E
  class WalletActor
    WALLET_BIN = File.expand_path('../../bin/wallet', __dir__).freeze

    def initialize(name)
      @name = name.to_sym
      ensure_env!
    end

    def identity_key
      wif = BSV::Wallet::Fixtures.wallet(@name).wif
      BSV::Wallet::KeyDeriver
        .new(private_key: BSV::Primitives::PrivateKey.from_wif(wif))
        .identity_key
    end

    def reset!
      db = Sequel.connect(BSV::Wallet::Fixtures.wallet(@name).database_url)
      tables = db.tables - %i[schema_migrations schema_info]
      db.run("TRUNCATE TABLE #{tables.join(',')} RESTART IDENTITY CASCADE") if tables.any?
    ensure
      db&.disconnect
    end

    def import!
      run_wallet('import', '--no-send')
    end

    def available_funds
      Integer(run_wallet('balance').strip, 10)
    end

    def send(identity_key, sats, no_fee: false)
      args = ['send', identity_key, sats.to_s, '--broadcast=none']
      args << '--no-fee' if no_fee
      run_wallet(*args)
    end

    def receive(envelope)
      run_wallet('receive', stdin_data: envelope)
    end

    private

    def run_wallet(*args, stdin_data: nil)
      cmd = [WALLET_BIN, "--wallet=#{@name}"] + args
      stdout, stderr, status = Open3.capture3(*cmd, stdin_data: stdin_data, binmode: true)
      raise "wallet #{args.first} (#{@name}) failed: #{stderr}" unless status.success?

      stdout
    end

    def ensure_env!
      env_key = "BSV_WALLET_WIF_#{@name.to_s.upcase}"

      # Derivation table is bounded — +WalletDerivation::WALLET_NAMES+
      # currently defines w1..w5. Names matching the +wN+ shape but
      # outside the table (e.g. +:w6+) fall through to the standard
      # +Fixtures+ lookup, which raises a clear "fixture has no WIF"
      # error if the env var is also unset. The earlier regex-based check
      # would have run the derivation and hit a generic +KeyError+ from
      # +Hash#fetch+ — harder to diagnose.
      if ENV[env_key].to_s.strip.empty? && WalletDerivation::WALLET_NAMES.include?(@name.to_s)
        sdk_wif = ENV.fetch('BSV_WALLET_WIF_SDK') do
          raise "BSV_WALLET_WIF_SDK required to derive #{@name}"
        end
        ENV[env_key] = WalletDerivation.derive_by_name(sdk_wif: sdk_wif).fetch(@name.to_s)
        BSV::Wallet::Fixtures.reset!
      end

      BSV::Wallet::Fixtures.load_config_file!
    end
  end
end
