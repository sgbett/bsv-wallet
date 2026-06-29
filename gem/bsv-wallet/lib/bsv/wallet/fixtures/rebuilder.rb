# frozen_string_literal: true

module BSV
  module Wallet
    module Fixtures
      # Rebuild dev-wallet databases from a clean slate. Operator
      # plumbing — not a runtime path.
      #
      # The +fixtures:rebuild+ rake task is the operator surface; this
      # class carries the orchestration so the rake wrapper stays a
      # thin shim and the logic is unit-testable with stubbed
      # boot/sweep/network calls.
      #
      # Three operations:
      #
      #   * +rebuild(name)+ — sweep current spendable UTXOs back to root,
      #     +DROP DATABASE+ the wallet's Postgres database, +CREATE+ it,
      #     re-run migrations, fund from +:sdk+ wallet.
      #
      #   * +rebuild_all+ — iterate the registry; skip +:test+ (no WIF;
      #     unit specs reset their own DB).
      #
      #   * +verify+ — for each registered wallet, assert post-refund state:
      #     no spendable rows from the previous era + non-zero root balance
      #     on chain. Returns the list of failing wallets (empty on success)
      #     — caller exits non-zero on any failure.
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
      # Wall time is chain-tip bound — sweep + fund are inline broadcasts.
      # Expect ~5-15 minutes for the full +alice/bob/carol/sdk/w1+..+w5+
      # fleet. One-shot pre-merge operation; not a CI loop.
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

        # Rebuild a single named wallet. Raises on hard failures (cannot
        # reach Postgres, +:sdk+ not registered, etc.). Soft conditions
        # (nothing to sweep, dust-only wallet) are logged and treated
        # as no-ops. Side-effecting — returns nil.
        def rebuild(name)
          sym = name.to_sym
          raise ArgumentError, "fixture wallet :#{sym} is not registered" unless @registry[sym]

          log "rebuild: #{sym}: sweeping..."
          sweep_to_root_safe(sym)

          db_name = postgres_db_name(sym)
          log "rebuild: #{sym}: dropping #{db_name}..."
          drop_database!(db_name)

          log "rebuild: #{sym}: creating #{db_name}..."
          create_database!(db_name)

          log "rebuild: #{sym}: migrating..."
          migrate!(sym)

          log "rebuild: #{sym}: funding #{@fund_sats} sats from :sdk..."
          fund_from_sdk!(sym)

          log "rebuild: #{sym}: done"
          nil
        end

        # Iterate the registry, rebuilding every entry except +SKIP_NAMES+
        # and any registered wallet whose WIF is missing (typically +w1+..+w5+
        # on a dev box that hasn't run the e2e harness to derive them).
        # +:sdk+ is rebuilt by re-funding from itself — no-op fund step (we
        # skip the sdk leg of the loop and the operator funds +:sdk+ externally).
        # Side-effecting — returns nil.
        def rebuild_all
          targets = eligible_targets
          log "rebuild_all: targets = #{targets.inspect}"

          # Process :sdk first so its fresh schema is in place before any
          # other wallet tries to fund from it. :sdk is funded externally
          # (mining / a sibling wallet) — the rebuild flow takes its
          # current on-chain balance as given.
          targets = ([:sdk] & targets) + (targets - [:sdk])

          targets.each do |name|
            if name == :sdk
              rebuild_sdk
            else
              rebuild(name)
            end
          end

          log "rebuild_all: complete (#{targets.length} wallets)"
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

        # +:sdk+ rebuild: sweep + drop + create + migrate, no re-fund.
        # The funder is funded externally; we treat its on-chain balance
        # as given and just refresh its database. Side-effecting —
        # returns nil.
        def rebuild_sdk
          log 'rebuild: sdk: sweeping...'
          sweep_to_root_safe(:sdk)

          db_name = postgres_db_name(:sdk)
          log "rebuild: sdk: dropping #{db_name}..."
          drop_database!(db_name)

          log "rebuild: sdk: creating #{db_name}..."
          create_database!(db_name)

          log 'rebuild: sdk: migrating...'
          migrate!(:sdk)

          log 'rebuild: sdk: re-importing root UTXOs from chain...'
          import_root!(:sdk)

          log 'rebuild: sdk: done'
          nil
        end

        # Sweep the wallet's current spendable UTXOs back to its root
        # P2PKH. Best-effort: missing WIF, empty pool, or any failure
        # logs + continues — the subsequent +DROP DATABASE+ is the real
        # blank-slate. Sweeping first salvages funds that would otherwise
        # be orphaned (the new CHECK literal wouldn't recognise the old
        # derived-key UTXOs).
        def sweep_to_root_safe(name)
          ctx = boot_wallet(name)
          result = ctx[:engine].sweep_to_root
          if result[:sweep].nil?
            log "  sweep: #{name}: nothing to sweep"
          else
            dtxid = result[:sweep][:wtxid].reverse.unpack1('H*')
            log "  sweep: #{name}: dtxid=#{dtxid}"
          end
        rescue StandardError => e
          log "  sweep: #{name}: skipped (#{e.class}: #{e.message})"
        end

        def drop_database!(db_name)
          admin_db = open_admin_connection
          begin
            admin_db.run(%(DROP DATABASE IF EXISTS "#{db_name}"))
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

        # Send +@fund_sats+ from +:sdk+ to the target wallet's root P2PKH.
        # The target wallet's key is read off its fixture WIF; the funding
        # output is locked to +hash160(target_identity_key_bytes)+ — the
        # literal root address recoverable by +bin/wallet import+.
        def fund_from_sdk!(name)
          # Capture the target's root pubkey before swapping the global
          # Sequel::Model.db over to :sdk — booting :sdk rebinds models
          # to the funder's DB so any subsequent reads of the target's
          # context would query the wrong wallet.
          target_ctx = boot_wallet(name)
          recipient_hash = target_ctx[:key_deriver].identity_pubkey_hash
          locking_script = BSV::Script::Script.p2pkh_lock(recipient_hash).to_binary

          sdk_ctx = boot_wallet(:sdk)
          result = sdk_ctx[:engine].build_action(
            description: "fund #{name}",
            outputs: [
              { satoshis: @fund_sats, locking_script: locking_script,
                spendable_intent: 'none', output_description: "fund #{name} root" }
            ],
            no_send: false,
            accept_delayed_broadcast: false,
            randomize_outputs: false
          )

          dtxid = result[:wtxid].reverse.unpack1('H*')
          log "  fund:  #{name}: dtxid=#{dtxid}"
        end

        # Re-import root UTXOs into the freshly-migrated +:sdk+ DB by
        # scanning its on-chain root address. The drop+create wiped the
        # action/output rows; +import_wallet+ rebuilds them from chain
        # state so subsequent +fund_from_sdk!+ calls have spendable
        # inputs to draw on.
        def import_root!(name)
          ctx = boot_wallet(name)
          result = ctx[:engine].import_wallet(no_send: false, accept_delayed_broadcast: false)
          log "  import: #{name}: imported #{result[:imported]} UTXO(s)"
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
