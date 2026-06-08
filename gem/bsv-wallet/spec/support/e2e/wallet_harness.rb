# frozen_string_literal: true

require 'bsv-wallet'
require_relative '../../../lib/bsv/wallet/cli'
require_relative 'wallet_derivation'

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
  #   - +BSV_WALLET_WIF_SDK+   — the funding key (mandatory)
  #   - +BSV_WALLET_POSTGRES+  — base Postgres URL (mandatory); +CLI.boot+
  #     derives each wallet's DB as +{base}/bsv_wallet_{name}+ via
  #     +derive_postgres_url+. Per-wallet +DATABASE_URL_<NAME>+ overrides
  #     are still respected (CLI prefers explicit overrides).
  #
  # Env vars written (in-process, never persisted):
  #   - +BSV_WALLET_WIF_W1+ .. +BSV_WALLET_WIF_W5+ — derived from SDK
  #   - +DATABASE_URL_SDK+ / +DATABASE_URL_W1+ .. +DATABASE_URL_W5+ —
  #     derived from +BSV_WALLET_POSTGRES+ via +CLI.derive_postgres_url+.
  #     Explicit +DATABASE_URL_<NAME>+ values already in ENV are respected.
  #     +e2e_workload_spec.rb+ reads these slots directly (stage 3 fanout
  #     verification opens a fresh +Sequel.connect+ per wallet), so they
  #     must be populated even though +CLI.boot+ would derive on its own.
  module WalletHarness
    SDK = 'sdk'

    module_function

    # Register the funder + the five derived test wallets into the
    # central +BSV::Wallet::Fixtures+ registry. Idempotent — calling
    # twice does no harm; subsequent calls overwrite with the same
    # values.
    #
    # Replaces the previous ENV-mutation pattern (which set
    # +BSV_WALLET_WIF_W1+ etc. in-process so +CLI.boot+'s legacy
    # +env_fetch+ chain would find them). Post-#292 +CLI.boot+ reads
    # named wallets through Fixtures, so the registration is the
    # whole job.
    #
    # Raises +KeyError+ when +BSV_WALLET_WIF_SDK+ is unset; raises a
    # clear error when +BSV_WALLET_POSTGRES+ is unset/blank (the
    # +Fixtures+ derivation would otherwise produce nil DB URLs and
    # downstream readers like +e2e_workload_spec.rb+ would fail
    # confusingly).
    def install_fixtures!
      raise KeyError, 'key not found: "BSV_WALLET_POSTGRES"' if ENV['BSV_WALLET_POSTGRES'].to_s.strip.empty?

      sdk_wif = ENV.fetch('BSV_WALLET_WIF_SDK')
      derived = E2E::WalletDerivation.derive_by_name(sdk_wif: sdk_wif)

      BSV::Wallet::Fixtures.configure do |f|
        f.postgres_base ||= ENV.fetch('BSV_WALLET_POSTGRES', nil)
        f.wallet :sdk, wif: sdk_wif
        derived.each { |name, wif| f.wallet name.to_sym, wif: wif }
      end
    end

    # Boot an in-process wallet context for +name+ (e.g. +'sdk'+,
    # +'w1'+). Returns the +CLI.boot+ hash:
    #   { engine:, utxo_pool:, key_deriver:, db:, identity_key:, private_key: }
    def boot(name, network: :mainnet)
      install_fixtures!
      BSV::Wallet::CLI.boot(wallet_name: name, network: network)
    end

    # Switch the process-global +Sequel::Model.db+ AND every model
    # subclass's cached dataset to +ctx+'s database.
    #
    # +CLI.boot+ / +Store.connect+ overwrites the global on every call,
    # so a process that boots more than one wallet (the harness does)
    # ends up with all +Sequel::Model+ operations routed to whichever
    # wallet booted last. The CLI tools dodge this because each one is
    # its own process — see the warning in +CLAUDE.md+.
    #
    # Setting +Sequel::Model.db = newdb+ alone is NOT enough: subclasses
    # like +Models::Action+ cache their own dataset at class load time,
    # and that dataset is bound to the original db. We have to rebind
    # each subclass's dataset explicitly.
    #
    # Call this before every +ctx[:engine]+ / +ctx[:utxo_pool]+
    # operation that touches the DB.
    def activate(ctx)
      Sequel::Model.db = ctx[:db]
      BSV::Wallet::Store::Models.constants.each do |const|
        klass = BSV::Wallet::Store::Models.const_get(const)
        next unless klass.is_a?(Class) && klass < Sequel::Model

        klass.dataset = ctx[:db][klass.table_name]
      end
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
    # the harness's stage-1 reset sweep.
    def sdk_identity_key
      sdk_pk = BSV::Primitives::PrivateKey.from_wif(ENV.fetch('BSV_WALLET_WIF_SDK'))
      BSV::Wallet::KeyDeriver.new(private_key: sdk_pk).identity_key
    end

    # Required env vars for the harness to run. Phase specs call this
    # in +before+ and +skip+ on missing entries.
    def required_env
      %w[BSV_WALLET_WIF_SDK BSV_WALLET_POSTGRES]
    end

    # Returns the names of any required env vars that are unset.
    def missing_env
      required_env.reject { |k| ENV[k].to_s.strip.length.positive? }
    end
  end
end
