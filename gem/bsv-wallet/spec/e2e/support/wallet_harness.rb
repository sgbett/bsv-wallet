# frozen_string_literal: true

require 'bsv-wallet'

module E2E
  # Boot in-process Engines for the funding wallet (+sdk+) and the five
  # derived test wallets (+w1+..+w5+).
  #
  # Reuses +BSV::Wallet::CLI.boot+ — it already does the right thing
  # (Store + Engine + multi-provider Services). The harness's only job
  # is to derive the five test WIFs from +BSV_WALLET_WIF_SDK+ and stash
  # them in ENV under the conventional +BSV_WALLET_WIF_<NAME>+ slots so
  # +CLI.boot(wallet_name: 'w1')+ picks them up.
  #
  # Env vars consumed:
  #   - +BSV_WALLET_WIF_SDK+  — the funding key (mandatory)
  #   - +DATABASE_URL_SDK+    — per-wallet Postgres URL
  #   - +DATABASE_URL_W1+ .. +DATABASE_URL_W5+ — per-wallet Postgres URLs
  #
  # Env vars written (in-process, never persisted):
  #   - +BSV_WALLET_WIF_W1+ .. +BSV_WALLET_WIF_W5+ — derived from SDK
  module WalletHarness
    SDK = 'sdk'

    module_function

    # Derive the five test-wallet WIFs from +BSV_WALLET_WIF_SDK+ and
    # install them into ENV. Idempotent — calling twice does no harm.
    def install_derived_wifs!
      sdk_wif = ENV.fetch('BSV_WALLET_WIF_SDK')
      wifs = E2E::WalletDerivation.derive_by_name(sdk_wif: sdk_wif)
      wifs.each do |name, wif|
        ENV["BSV_WALLET_WIF_#{name.upcase}"] = wif
      end
    end

    # Boot an in-process wallet context for +name+ (e.g. +'sdk'+,
    # +'w1'+). Returns the +CLI.boot+ hash:
    #   { engine:, utxo_pool:, key_deriver:, db:, identity_key:, private_key: }
    def boot(name, network: :mainnet)
      install_derived_wifs!
      BSV::Wallet::CLI.boot(wallet_name: name, network: network)
    end

    # All test wallet names except SDK.
    def test_wallet_names
      E2E::WalletDerivation::WALLET_NAMES
    end

    # All wallet names (SDK + test).
    def all_wallet_names
      [SDK] + test_wallet_names
    end

    # The SDK identity key as a hex string — the canonical target for
    # the cleanup sweep in Phase 4.
    def sdk_identity_key
      sdk_pk = BSV::Primitives::PrivateKey.from_wif(ENV.fetch('BSV_WALLET_WIF_SDK'))
      BSV::Wallet::KeyDeriver.new(private_key: sdk_pk).identity_key
    end

    # Required env vars for the harness to run. Phase specs call this
    # in +before+ and +skip+ on missing entries.
    def required_env
      %w[BSV_WALLET_WIF_SDK DATABASE_URL_SDK] +
        test_wallet_names.map { |n| "DATABASE_URL_#{n.upcase}" }
    end

    # Returns the names of any required env vars that are unset.
    def missing_env
      required_env.reject { |k| ENV[k].to_s.strip.length.positive? }
    end
  end
end
