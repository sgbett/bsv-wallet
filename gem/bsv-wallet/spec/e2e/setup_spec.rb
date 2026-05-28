# frozen_string_literal: true

# Phase 1 of the #126 e2e on-chain harness.
#
# Goal: bring the five test wallets to a known starting position —
# each holding exactly 10_000_000 sats, freshly funded from
# +BSV_WALLET_WIF_SDK+ and confirmed on chain.
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
#   4. Poll get_tx_status for each funding dtxid until every funding
#      tx reaches a mined status (MINED / IMMUTABLE / SEEN_IN_ORPHAN_MEMPOOL
#      → with a block hash). The HLR requires confirmation before
#      Phase 2 starts so the fragmentation cascade can build BEEF on
#      top of confirmed inputs.
#
# Restart safety: if Phase 1 aborts after a partial fund, re-running
# starts by draining whatever's there and funding from scratch —
# step 2's sweep handles the inherited balance.

require_relative 'spec_helper'

RSpec.describe 'e2e Phase 1 — drain + fund + confirm' do # rubocop:disable RSpec/DescribeClass
  let(:fund_satoshis) { 10_000_000 }
  let(:confirmation_timeout_s) { (ENV['SETUP_CONFIRM_TIMEOUT_S'] || 1500).to_i }
  let(:confirmation_poll_interval_s) { (ENV['SETUP_CONFIRM_POLL_S'] || 30).to_i }
  # ARC status values that mean "in a block" (per BIP270 / ARC docs).
  let(:mined_statuses) { %w[MINED IMMUTABLE].freeze }

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

  # Send +fund_satoshis+ from SDK to +recipient_identity+, broadcasting
  # synchronously. The recipient then internalizes the BEEF.
  # Returns the funding dtxid (display order, hex) so the caller can
  # poll for confirmation.
  def fund_wallet(sdk:, recipient_ctx:)
    payment = sdk[:engine].send_payment(
      recipient: recipient_ctx[:key_deriver].identity_key,
      satoshis: fund_satoshis,
      no_send: false, accept_delayed_broadcast: false
    )

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

  # Poll the funding tx's status via the SDK Engine's Services until
  # it shows up in a block — or +confirmation_timeout_s+ elapses.
  # Reusing the SDK's Services (rather than a fresh one) preserves
  # broadcast affinity: the provider that accepted the funding tx is
  # tried first on each poll, so MINED detection lands on the right
  # ARC instance immediately.
  #
  # Returns the final status string.
  def wait_for_mined(sdk:, dtxid:)
    deadline = monotonic_now + confirmation_timeout_s
    last_status = nil

    while monotonic_now < deadline
      result = sdk[:engine].services.call(:get_tx_status, txid: dtxid)
      last_status = result&.data&.dig(:tx_status) || result&.data&.dig('tx_status')

      BSV::Wallet.emit('e2e.confirm.poll', dtxid: dtxid, status: last_status)
      return last_status if mined_statuses.include?(last_status)

      sleep confirmation_poll_interval_s
    end

    last_status
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  it 'drains existing balances and funds each test wallet with 10M sats' do
    BSV::Wallet.emit('e2e.phase1.start',
                     wallets: E2E::WalletHarness.test_wallet_names.join(','))

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

    # Step 3 — drain each Wn back to SDK
    test_ctxs.each do |name, ctx|
      drain_wallet(ctx, sdk_identity: sdk_identity)
    rescue StandardError => e
      # Best-effort drain — log and continue. The funding step will
      # still succeed even if drain left orphaned outputs on chain
      # (they're just SDK-unreachable dust at that point).
      BSV::Wallet.emit('e2e.drain.failed', wallet: name, error: e.message.lines.first&.chomp)
    end

    # Step 4 — fund each Wn from SDK
    funding_dtxids = test_ctxs.each_with_object({}) do |(name, ctx), acc|
      acc[name] = fund_wallet(sdk: sdk, recipient_ctx: ctx)
    end

    # Step 5 — wait for confirmation on every funding tx
    final_statuses = funding_dtxids.each_with_object({}) do |(name, dtxid), acc|
      acc[name] = wait_for_mined(sdk: sdk, dtxid: dtxid)
    end

    BSV::Wallet.emit('e2e.phase1.complete',
                     mined: final_statuses.count { |_, s| mined_statuses.include?(s) })

    # Assertions
    final_statuses.each do |name, status|
      expect(mined_statuses).to include(status),
                                "#{name}: funding tx ended at #{status.inspect}, expected MINED/IMMUTABLE"
    end

    test_ctxs.each do |name, ctx|
      expect(ctx[:utxo_pool].balance).to be >= fund_satoshis - 200,
                                         "#{name}: balance #{ctx[:utxo_pool].balance} < #{fund_satoshis - 200}"
    end
  end
end
