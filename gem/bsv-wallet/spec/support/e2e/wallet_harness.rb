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
  #     +broadcast_spec.rb+ reads these slots directly (stage 3 fanout
  #     verification opens a fresh +Sequel.connect+ per wallet), so they
  #     must be populated even though +CLI.boot+ would derive on its own.
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

    # Derive per-wallet Postgres URLs from +BSV_WALLET_POSTGRES+ and
    # install them into ENV for each wallet name (+sdk+ + +w1+..+w5+).
    # Reuses +CLI.derive_postgres_url+ so the derivation rule lives in
    # one place.
    #
    # Respects explicit +DATABASE_URL_<NAME>+ overrides — only fills empty
    # slots, so a single wallet can be pointed at a different host without
    # losing derivation for the others. Diverges from +install_derived_wifs!+
    # (unconditional overwrite) deliberately: WIFs are cryptographically
    # derived and overrides aren't meaningful, DB URLs are operationally
    # derived and overrides are.
    #
    # Raises +KeyError+ when +BSV_WALLET_POSTGRES+ is unset, blank, or
    # whitespace-only — matches +missing_env+'s whitespace-as-unset
    # semantics so a blank base never silently falls through (a blank
    # base would make +CLI.derive_postgres_url+ return nil, which would
    # blank out +ENV[key]+ and crash downstream readers like
    # +broadcast_spec.rb:374+'s +ENV.fetch+).
    def install_derived_db_urls!
      raise KeyError, 'key not found: "BSV_WALLET_POSTGRES"' if ENV['BSV_WALLET_POSTGRES'].to_s.strip.empty?

      all_wallet_names.each do |name|
        key = "DATABASE_URL_#{name.upcase}"
        next if ENV[key].to_s.strip.length.positive?

        ENV[key] = BSV::Wallet::CLI.derive_postgres_url(name)
      end
    end

    # Boot an in-process wallet context for +name+ (e.g. +'sdk'+,
    # +'w1'+). Returns the +CLI.boot+ hash:
    #   { engine:, utxo_pool:, key_deriver:, db:, identity_key:, private_key: }
    def boot(name, network: :mainnet)
      install_derived_wifs!
      install_derived_db_urls!
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
