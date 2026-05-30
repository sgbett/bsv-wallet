# frozen_string_literal: true

# Phase 1 of the #126 e2e on-chain harness.
#
# Goal: bring the five test wallets to a known starting position —
# each holding ~10_000_000 sats of newly-funded inbound, accepted
# by ARC. No block-confirmation wait: the synchronous broadcast
# (+accept_delayed_broadcast: false+) returns when ARC accepts the
# tx, and the BEEF carries proofs down to confirmed ancestors so the
# recipient's +internalize_action+ can verify SPV immediately. The
# subject tx's own proof shows up later via the daemon's TxProof
# loop — not Phase 1's concern.
#
# Sequence:
#   1. TRUNCATE every wallet's DB so derivation / output tracking
#      starts clean (per-run isolation — the harness owns these DBs).
#   2. For each test wallet: scan its root address for on-chain UTXOs
#      (a previous run may have aborted leaving balance behind), then
#      sweep that balance back to the SDK identity (synchronous
#      broadcast). Best-effort — wallets with zero balance just skip
#      the sweep.
#   3. SDK pays 10_000_000 sats to each test wallet (synchronous
#      broadcast). The recipient internalizes the BEEF so the funding
#      output is tracked locally.
#
# Restart safety: if Phase 1 aborts after a partial fund, re-running
# starts by draining whatever's there and funding from scratch —
# step 2's sweep handles the inherited balance.

require_relative 'spec_helper'
require 'sequel'

RSpec.describe 'e2e Phase 1 — drain + fund' do # rubocop:disable RSpec/DescribeClass
  let(:fund_satoshis) { (ENV['SETUP_FUND_SATS'] || 10_000_000).to_i }

  before do
    missing = E2E::WalletHarness.missing_env
    skip "Phase 1 requires env: #{missing.join(', ')}" unless missing.empty?
    E2E::EventLog.start
  end

  after do
    E2E::EventLog.stop
  end

  # TRUNCATE each wallet's DB so per-run derivation/output tracking
  # starts from zero. Sequel-level TRUNCATE works against both Postgres
  # and SQLite (the SQLite path uses .delete; CASCADE is Postgres-only).
  def reset_wallet_db(name)
    db = Sequel.connect(ENV.fetch("DATABASE_URL_#{name.upcase}"))
    tables = db.tables - %i[schema_migrations schema_info]
    return if tables.empty?

    if db.database_type == :postgres
      db.run("TRUNCATE TABLE #{tables.join(',')} RESTART IDENTITY CASCADE")
    else
      tables.each { |t| db[t].delete }
    end
  ensure
    db&.disconnect
  end

  # Drain whatever +Wn+ currently holds on chain to +sdk_identity+.
  # Returns the broadcast result hash (with a +txid+ wtxid) or nil if
  # the wallet had nothing to sweep.
  def drain_wallet(ctx, sdk_identity:)
    E2E::WalletHarness.activate(ctx)

    # Scan the wallet's root address for on-chain UTXOs (a prior run
    # may have left balance behind). +import_wallet+ wraps each into
    # the wallet's tracked state. Empty result is fine — Wn might be
    # brand new.
    import_result = ctx[:engine].import_wallet
    BSV::Wallet.emit('e2e.import', wallet: ctx[:key_deriver].identity_key[0..8],
                                   imported: import_result[:found] || 0)

    return nil if ctx[:utxo_pool].balance.zero?

    sweep_result = ctx[:engine].sweep(
      recipient: sdk_identity,
      no_send: false, accept_delayed_broadcast: false
    )
    return nil if sweep_result.nil?

    sweep_dtxid = sweep_result[:txid].reverse.unpack1('H*')
    BSV::Wallet.emit('e2e.drain', dtxid: sweep_dtxid, satoshis: ctx[:utxo_pool].balance)
    sweep_result
  end

  # Send +fund_satoshis+ from SDK to +recipient_ctx+, broadcasting
  # synchronously. The recipient then internalizes the BEEF.
  # Returns the funding dtxid (display order, hex) for the summary.
  def fund_wallet(sdk:, recipient_ctx:)
    E2E::WalletHarness.activate(sdk)
    payment = sdk[:engine].send_payment(
      recipient: recipient_ctx[:key_deriver].identity_key,
      satoshis: fund_satoshis,
      no_send: false, accept_delayed_broadcast: false
    )

    E2E::WalletHarness.activate(recipient_ctx)
    recipient_ctx[:engine].internalize_action(
      tx: payment[:beef],
      outputs: payment[:outputs].map do |o|
        {
          output_index: o[:vout], satoshis: o[:satoshis],
          protocol: 'wallet payment',
          payment_remittance: {
            derivation_prefix: o[:derivation_prefix],
            derivation_suffix: o[:derivation_suffix],
            sender_identity_key: payment[:sender_identity_key]
          }
        }
      end,
      description: 'phase 1 funding from SDK'
    )

    dtxid = payment[:beef][-32..].reverse.unpack1('H*')
    BSV::Wallet.emit('e2e.fund', dtxid: dtxid,
                                 wallet: recipient_ctx[:key_deriver].identity_key[0..8],
                                 satoshis: fund_satoshis)
    dtxid
  end

  it 'drains existing balances and funds each test wallet' do
    BSV::Wallet.emit('e2e.phase1.start',
                     wallets: E2E::WalletHarness.test_wallet_names.join(','),
                     fund_satoshis: fund_satoshis)

    # Step 1 — clean DBs
    E2E::WalletHarness.all_wallet_names.each { |n| reset_wallet_db(n) }

    # Step 2 — boot in-process engines
    E2E::WalletHarness.install_derived_wifs!
    sdk = E2E::WalletHarness.boot('sdk')
    test_ctxs = E2E::WalletHarness.test_wallet_names.to_h do |name|
      [name, E2E::WalletHarness.boot(name)]
    end

    sdk_identity = sdk[:key_deriver].identity_key
    BSV::Wallet.emit('e2e.engines.booted', count: 6, sdk: sdk_identity[0..8])

    # Step 3a — bring SDK's on-chain UTXOs under wallet management.
    # After TRUNCATE the SDK DB is empty; +import_wallet+ scans its
    # root address for the funding UTXOs.
    #
    # +no_send: false+ broadcasts Phase 2's BRC-42 self-payment to
    # chain. The smoke is an "everything broadcasts" run — if Phase 2
    # stayed off-chain (the CI default), every subsequent SDK-side
    # broadcast would reference a UTXO Teranode has never heard of and
    # be rejected. The rule is binary: broadcast all, or broadcast none.
    E2E::WalletHarness.activate(sdk)
    sdk_import = sdk[:engine].import_wallet(no_send: false,
                                            accept_delayed_broadcast: false)
    sdk_balance = sdk[:utxo_pool].balance
    BSV::Wallet.emit('e2e.sdk.imported',
                     found: sdk_import[:found] || 0, balance: sdk_balance)

    # Step 3 — drain each Wn back to SDK (best-effort)
    test_ctxs.each do |name, ctx|
      drain_wallet(ctx, sdk_identity: sdk_identity)
    rescue StandardError => e
      BSV::Wallet.emit('e2e.drain.failed', wallet: name, error: e.message.lines.first&.chomp)
    end

    # Step 4 — fund each Wn from SDK
    funding_dtxids = test_ctxs.each_with_object({}) do |(name, ctx), acc|
      acc[name] = fund_wallet(sdk: sdk, recipient_ctx: ctx)
    end

    BSV::Wallet.emit('e2e.phase1.complete', funded: funding_dtxids.size)

    # The synchronous broadcast already returned; if +fund_wallet+
    # didn't raise then ARC accepted the tx and the recipient's
    # +internalize_action+ verified SPV against the ancestor chain.
    # Recipient balance reflects the funding output immediately.
    test_ctxs.each do |name, ctx|
      E2E::WalletHarness.activate(ctx)
      expect(ctx[:utxo_pool].balance).to be >= fund_satoshis - 200,
                                         "#{name}: balance #{ctx[:utxo_pool].balance} < #{fund_satoshis - 200}"
    end
  end
end
