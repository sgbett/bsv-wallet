# frozen_string_literal: true

module BSV
  module Wallet
    module Fixtures
      # Rebuild dev-wallet databases from a clean slate. Operator
      # plumbing — not a runtime path.
      #
      # The +fixtures:*+ rake tasks are the operator surface; this class
      # carries the orchestration so the rake wrappers stay thin shims
      # and the logic is unit-testable with stubbed boot/sweep/network
      # calls.
      #
      # Four operations — schema lifecycle is intentionally separate
      # from on-chain mutation (no bundled "rebuild and fund" path —
      # see #493 for the rationale):
      #
      #   * +rebuild(name)+ — sweep current spendable UTXOs back to the
      #     wallet's own root, +DROP DATABASE+, +CREATE+, re-run
      #     migrations. Leaves the wallet in clean-schema state with
      #     zero rows. **Aborts if sweep fails** — an operator-visible
      #     signal that the wallet held funds that couldn't be moved
      #     (typically mid-convention-flip; investigation warranted).
      #
      #   * +rebuild_all+ — iterate the registry; skip +:test+ (no WIF)
      #     and any wallet whose WIF is missing.
      #
      #   * +fund(name, sats:)+ — send +sats+ from +:sdk+ to +name+'s
      #     root P2PKH. Explicit, opt-in; never bundled with rebuild.
      #     Rejects +:sdk+ (the funder cannot fund itself).
      #
      #   * +verify+ — for each registered wallet, assert no stale
      #     spendable rows + non-zero root balance on chain. Returns
      #     the failing-wallets list (empty on success) — caller exits
      #     non-zero on any failure. The "non-zero root balance" check
      #     is post-fund expectation: a freshly-rebuilt-but-unfunded
      #     wallet will (correctly) fail verify.
      #
      # Drop+create over +DELETE FROM+ for three reasons (Database Architect
      # input on #480):
      #
      #   1. The per-wallet +outputs.spendable_recoverable+ CHECK literal
      #      embeds the WIF-derived root P2PKH script. Re-running migrations
      #      against a fresh DB rebakes the literal cleanly; a +DELETE+ leaves
      #      a stale CHECK against the previous WIF.
      #   2. ENUMs survive a +DELETE+ — adding/removing an ENUM value would
      #      require manual surgery.
      #   3. CASCADE FK ordering across promotions → spendable → outputs is
      #      non-trivial for a +DELETE+ sweep; +DROP DATABASE+ is atomic.
      #
      # Wall time is chain-tip bound — sweep is an inline broadcast.
      # Expect a minute or two per wallet. One-shot pre-release
      # operation; not a CI loop.
      class Rebuilder
        # Default amount to fund each rebuilt wallet from +:sdk+ — matches
        # the CLAUDE.md convention that integration WIFs each carry
        # >=1m sats on chain.
        DEFAULT_FUND_SATS = 1_000_000

        # Names that never get rebuilt by +rebuild_all+. +:test+ has no
        # WIF (unit specs generate their own keys) and the test DB is
        # truncated by the spec suite's +before(:suite)+ hook — not by
        # operator action.
        SKIP_NAMES = %i[test].freeze

        # @param registry [BSV::Wallet::Fixtures::Registry] usually
        #   +BSV::Wallet::Fixtures.registry+.
        # @param out [IO] status output. Defaults to +$stderr+ so the
        #   operator sees progress.
        # @param fund_sats [Integer] satoshis to send from +:sdk+ on
        #   re-fund.
        def initialize(registry: BSV::Wallet::Fixtures.registry,
                       out: $stderr,
                       fund_sats: DEFAULT_FUND_SATS)
          @registry = registry
          @out = out
          @fund_sats = fund_sats
        end

        # Rebuild a single named wallet's database to clean-schema
        # state: sweep current spendable UTXOs back to the wallet's
        # own root, +DROP DATABASE+, +CREATE+, re-run migrations.
        # Side-effecting — returns nil.
        #
        # **Aborts on sweep failure.** If the wallet held spendable
        # rows that the engine couldn't sign or broadcast (typically:
        # mid-convention-flip, where derived keys can't be
        # re-computed under the new convention), the exception is
        # propagated up — the drop + create + migrate never run.
        # Operator should investigate the failed sweep before
        # blowing away the DB.
        def rebuild(name)
          sym = name.to_sym
          raise ArgumentError, "fixture wallet :#{sym} is not registered" unless @registry[sym]

          log "rebuild: #{sym}: sweeping..."
          sweep_to_root!(sym)

          db_name = postgres_db_name(sym)
          log "rebuild: #{sym}: dropping #{db_name}..."
          drop_database!(db_name)

          log "rebuild: #{sym}: creating #{db_name}..."
          create_database!(db_name)

          log "rebuild: #{sym}: migrating..."
          migrate!(sym)

          log "rebuild: #{sym}: done"
          nil
        end

        # Iterate the registry, rebuilding every entry except
        # +SKIP_NAMES+ and any registered wallet whose WIF is missing.
        # Each wallet's +rebuild+ is independent — no special ordering
        # required (fund is a separate operation; no inter-wallet
        # dependency during rebuild).
        #
        # A failing wallet does NOT abort the fleet: the exception is
        # logged and caught, the loop continues to the next wallet,
        # and the final summary lists what failed. Caller (the rake
        # task) exits non-zero when the returned array is non-empty.
        # Rationale: an operator running the bulk variant after a
        # wide change typically wants the rest of the fleet attempted
        # even if one wallet's sweep refuses; the per-wallet failures
        # surface at the end for triage.
        #
        # @return [Array<Array(Symbol, Exception)>] empty on success;
        #   +[name, exception]+ pairs for each failed wallet otherwise.
        def rebuild_all
          targets = eligible_targets
          log "rebuild_all: targets = #{targets.inspect}"

          failures = []
          targets.each do |name|
            rebuild(name)
          rescue StandardError => e
            failures << [name, e]
            log "rebuild: #{name}: FAILED — #{e.class}: #{e.message}"
          end

          if failures.empty?
            log "rebuild_all: complete (#{targets.length} wallets)"
          else
            log "rebuild_all: #{failures.length} of #{targets.length} wallet(s) failed"
            log "  failed: #{failures.map(&:first).inspect}"
          end
          failures
        end

        # Fund a wallet by sending +sats+ from +:sdk+ to its root P2PKH.
        # Explicit, opt-in operation — never bundled with +rebuild+.
        # Rejects +:sdk+ (the funder cannot fund itself).
        # Side-effecting — returns nil.
        #
        # @param name [Symbol, String] target wallet name (must be
        #   registered, must carry a WIF, must not be +:sdk+).
        # @param sats [Integer] satoshis to send.
        def fund(name, sats: @fund_sats)
          sym = name.to_sym
          raise ArgumentError, "fixture wallet :#{sym} is not registered" unless @registry[sym]
          raise ArgumentError, ':sdk is the funder and cannot fund itself' if sym == :sdk
          raise ArgumentError, "sats must be a positive Integer (got #{sats.inspect})" \
            unless sats.is_a?(Integer) && sats.positive?

          log "fund: #{sym}: sending #{sats} sats from :sdk..."
          fund_from_sdk!(sym, sats: sats)
          log "fund: #{sym}: done"
          nil
        end

        # Post-rebuild check. For each registered non-skipped wallet:
        #
        #   * Boot the wallet, assert no spendable rows from the previous
        #     era survive (+spendable_count == 0+ — every spendable output
        #     must come from a fresh fund post-rebuild).
        #   * Probe the on-chain root P2PKH balance via the wallet's
        #     network provider — non-zero confirms re-funding landed
        #     and the wallet is recoverable from its WIF alone.
        #
        # @return [Array<Array(Symbol, String)>] empty on success;
        #   +[name, reason]+ pairs for each failing wallet otherwise.
        #   Caller (the rake task) translates an empty array to exit 0.
        def verify
          targets = eligible_targets
          log "verify: targets = #{targets.inspect}"

          failures = []
          targets.each do |name|
            ok, reason = verify_one(name)
            if ok
              log "verify: #{name}: OK"
            else
              failures << [name, reason]
              log "verify: #{name}: FAIL — #{reason}"
            end
          end

          if failures.empty?
            log 'verify: all wallets OK'
          else
            log "verify: #{failures.length} wallet(s) failed"
          end
          failures
        end

        private

        # Names eligible for rebuild + verify: registered, not in
        # +SKIP_NAMES+, and carrying a WIF. The WIF check filters out
        # the e2e fleet (+w1+..+w5+) on a dev box that hasn't set
        # +BSV_WALLET_WIF_W*+ — operating on them without a key would
        # fail at boot.
        def eligible_targets
          @registry.names.reject do |name|
            SKIP_NAMES.include?(name) || @registry[name].wif.nil?
          end
        end

        # Sweep the wallet's current spendable UTXOs back to its own
        # root P2PKH. Re-raises on any failure — the caller (+rebuild+)
        # halts before the irreversible drop. A wallet with no
        # spendable rows returns +result[:sweep].nil?+ (no broadcast,
        # logged as no-op); this is the only "soft" condition.
        #
        # Rationale for re-raising vs catch-and-continue: a sweep
        # failure on a non-empty pool means signing or broadcast
        # failed on real (or believed-real) funds. Dropping the DB
        # without investigation discards the wallet's only memory of
        # those rows. Better to surface the failure and let the
        # operator decide.
        def sweep_to_root!(name)
          ctx = boot_wallet(name)
          result = ctx[:engine].sweep_to_root
          if result[:sweep].nil?
            log "  sweep: #{name}: nothing to sweep"
          else
            dtxid = result[:sweep][:wtxid].reverse.unpack1('H*')
            log "  sweep: #{name}: dtxid=#{dtxid}"
          end
        end

        def drop_database!(db_name)
          # The wallet's own Sequel::Model.db pool (from +boot_wallet+
          # earlier in +rebuild+) still holds a connection to this DB,
          # so a plain DROP races on +PG::ObjectInUse+. +WITH (FORCE)+
          # (Postgres 13+) terminates active sessions atomically before
          # dropping — covers our own pool and any stray operator
          # session (psql, GUI client) without a separate dance.
          admin_db = open_admin_connection
          begin
            admin_db.run(%(DROP DATABASE IF EXISTS "#{db_name}" WITH (FORCE)))
          ensure
            admin_db.disconnect
          end
        end

        def create_database!(db_name)
          admin_db = open_admin_connection
          begin
            admin_db.run(%(CREATE DATABASE "#{db_name}"))
          ensure
            admin_db.disconnect
          end
        end

        # Boot the wallet — CLI.boot runs migrate! internally, so a fresh
        # CREATE DATABASE followed by boot gets the schema installed.
        def migrate!(name)
          boot_wallet(name)
        end

        # Send +sats+ from +:sdk+ to the target wallet's root P2PKH.
        # The target wallet's key is read off its fixture WIF; the
        # funding output is locked to the wallet's root P2PKH hash —
        # the literal address recoverable by +bin/wallet import+.
        def fund_from_sdk!(name, sats:)
          # Capture the target's root pubkey hash before swapping the
          # global Sequel::Model.db over to :sdk — booting :sdk
          # rebinds models to the funder's DB so any subsequent reads
          # of the target's context would query the wrong wallet.
          target_ctx = boot_wallet(name)
          recipient_hash = target_ctx[:key_deriver].identity_pubkey_hash
          locking_script = BSV::Script::Script.p2pkh_lock(recipient_hash).to_binary

          sdk_ctx = boot_wallet(:sdk)
          result = sdk_ctx[:engine].build_action(
            description: "fund #{name}",
            outputs: [
              { satoshis: sats, locking_script: locking_script,
                spendable_intent: 'none', output_description: "fund #{name} root" }
            ],
            no_send: false,
            accept_delayed_broadcast: false,
            randomize_outputs: false
          )

          dtxid = result[:wtxid].reverse.unpack1('H*')
          log "  fund:  #{name}: dtxid=#{dtxid}"
        end

        # Boot the wallet through the shared CLI helper. Each call
        # rebinds +Sequel::Model.db+ + every model's +dataset+ to the
        # new wallet's connection (via +Store#migrate!+'s +bind_models!+
        # tail) — safe to call repeatedly within one process.
        def boot_wallet(name)
          require 'bsv/wallet/cli'
          BSV::Wallet::CLI.boot(wallet_name: name.to_s)
        end

        # Probe + assert one wallet. Returns [ok, reason].
        def verify_one(name)
          ctx = boot_wallet(name)
          spendable_count = ctx[:utxo_pool].spendable_count
          return [false, "#{spendable_count} stale spendable row(s)"] if spendable_count.positive?

          balance = root_balance(ctx)
          return [false, 'zero root balance on chain'] if balance.zero?

          [true, nil]
        rescue StandardError => e
          [false, "#{e.class}: #{e.message}"]
        end

        # Sum satoshis at the wallet's root P2PKH address via the wallet's
        # network provider. Mirrors +Engine#import_wallet+'s scan path
        # (the same +:get_utxos+ command on the same provider) — what we
        # import is what we count.
        def root_balance(ctx)
          address = ctx[:key_deriver].root_private_key.public_key.address
          provider = ctx[:engine].instance_variable_get(:@network_provider)
          return 0 unless provider

          result = provider.call(:get_utxos, address)
          return 0 if result.http_not_found?
          return 0 unless result.http_success?

          utxos = result.data
          return 0 if utxos.nil? || utxos.empty?

          utxos.sum { |u| u['value'].to_i }
        end

        def open_admin_connection
          require 'sequel'
          Sequel.connect(admin_url)
        end

        # Resolve the Postgres admin endpoint — the +postgres+ system
        # database on the same server as the registry's +postgres_base+.
        # Connecting to a database we are about to drop or create fails
        # (the target database can't be open during DDL), so we route
        # the +DROP+/+CREATE+ through the +postgres+ DB instead.
        def admin_url
          base = registry_postgres_base
          raise ArgumentError, 'postgres_base is not configured on the fixtures registry' if base.nil? || base.empty?

          "#{base.chomp('/')}/postgres"
        end

        # Per-wallet Postgres database name — mirrors the convention in
        # +Registry#derive_database_url+ so the rake task drops what the
        # gem-default fixtures file registers.
        def postgres_db_name(name)
          "bsv_wallet_#{name}"
        end

        def registry_postgres_base
          @registry.postgres_base
        end

        def log(msg)
          @out.puts(msg)
        end
      end
    end
  end
end
