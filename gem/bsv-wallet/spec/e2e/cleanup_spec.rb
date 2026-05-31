# frozen_string_literal: true

# Phase 4 of the #126 e2e on-chain harness — sweep back to SDK.
#
# Restores each test wallet to zero spendable via +Engine#sweep_to_root+,
# which loops +consolidate_step+ until the wallet has < +target_inputs+
# spendable outputs (the 20-smallest + 1-largest input shape ensures fee
# coverage even when the smallest are below the per-input marginal fee),
# then +sweep+s the remainder to the recipient's root P2PKH. Here the
# recipient is the SDK identity_key, so every test wallet drains to the
# literal address SDK was originally funded at. Each tx broadcasts on
# chain (no_send: false, accept_delayed_broadcast: false).
#
# After the test wallets drain, SDK self-sweeps its own residual change
# to root via the same path, then +import_wallet+ rescans to pull in
# every output now sitting at the root address (the W1..W5 sweeps plus
# the SDK self-sweep). The recovery-floor assertion checks SDK reclaimed
# the funded balance.
#
# No block-confirmation wait — synchronous broadcast acceptance is
# the success signal. The daemon's TxProof loop attaches proofs
# later in the background; the Wn→zero-spendable assertion and the
# recovery-floor assertion both read state available immediately
# after broadcast.
#
# Restart-safe per HLR: running this phase standalone restores the
# wallets to a state where a fresh Phase 1 can begin. If invoked
# without a preceding run, it does no harm — sweep_to_root drains
# nothing when the wallet has no spendable outputs.

require_relative 'spec_helper'

RSpec.describe 'e2e Phase 4 — consolidate + sweep to SDK' do # rubocop:disable RSpec/DescribeClass
  let(:target_inputs)           { (ENV['CLEANUP_TARGET_INPUTS'] || 20).to_i }
  let(:recovery_floor_fraction) { (ENV['CLEANUP_RECOVERY_FLOOR']  || 0.95).to_f }
  let(:funding_per_wallet)      { (ENV['CLEANUP_FUND_PER_WALLET'] || 10_000_000).to_i }

  before do
    missing = E2E::WalletHarness.missing_env
    skip "Phase 4 requires env: #{missing.join(', ')}" unless missing.empty?
    E2E::EventLog.start
  end

  after { E2E::EventLog.stop }

  it 'consolidates and sweeps every test wallet back to SDK with >= 95% recovery' do
    BSV::Wallet.emit('e2e.phase4.start',
                     target_inputs: target_inputs,
                     recovery_floor: recovery_floor_fraction)

    # Boot in-process engines.
    E2E::WalletHarness.install_derived_wifs!
    sdk = E2E::WalletHarness.boot('sdk')
    test_ctxs = E2E::WalletHarness.test_wallet_names.to_h do |name|
      [name, E2E::WalletHarness.boot(name)]
    end

    E2E::WalletHarness.activate(sdk)
    sdk_identity = sdk[:key_deriver].identity_key
    sdk_starting_balance = sdk[:utxo_pool].balance
    BSV::Wallet.emit('e2e.phase4.balances.start',
                     sdk_balance: sdk_starting_balance,
                     test_balances: test_ctxs.transform_values do |c|
                       E2E::WalletHarness.activate(c)
                       c[:utxo_pool].balance
                     end.to_s)

    # Step 1 — drain each Wn back to SDK's root address. sweep_to_root
    # consolidates down to < target_inputs spendable, then sweeps the
    # remainder to the literal SDK root P2PKH (+hash160(sdk_identity)+).
    # The funds land at the address SDK was originally funded at, so SDK
    # recovers them via the next +import_wallet+ scan with no derivation
    # context to keep — the wallet's DB carries no information the WIF +
    # the chain don't already provide. Every tx broadcasts on chain.
    wn_results = test_ctxs.map do |name, ctx|
      E2E::WalletHarness.activate(ctx)
      result = ctx[:engine].sweep_to_root(recipient: sdk_identity, target_inputs: target_inputs)
      dtxid = result[:sweep] && result[:sweep][:txid].reverse.unpack1('H*')
      BSV::Wallet.emit('e2e.cleanup.sweep_to_root',
                       wallet: name,
                       consolidation_steps: result[:consolidation_steps],
                       dtxid: dtxid, swept: !dtxid.nil?)
      result
    end
    consolidation_steps = wn_results.sum { |r| r[:consolidation_steps] }
    sweep_count = wn_results.count { |r| r[:sweep] }

    # Step 2 — SDK self-sweep: drain SDK's own residual change (the
    # BRC-42-derived outputs from Phase 1's outbound payments) back to
    # its root address via the same path. After this every SDK-controlled
    # UTXO is at the literal root P2PKH — the wallet's DB carries no
    # derivation context past this point.
    E2E::WalletHarness.activate(sdk)
    sdk_result = sdk[:engine].sweep_to_root(recipient: sdk_identity, target_inputs: target_inputs)
    sdk_sweep_dtxid = sdk_result[:sweep] && sdk_result[:sweep][:txid].reverse.unpack1('H*')
    if sdk_sweep_dtxid
      BSV::Wallet.emit('e2e.cleanup.sdk_self_sweep',
                       consolidation_steps: sdk_result[:consolidation_steps],
                       dtxid: sdk_sweep_dtxid)
    else
      BSV::Wallet.emit('e2e.cleanup.sdk_self_sweep.skipped', reason: 'no_spendable')
    end

    # Step 3 — re-scan SDK to pick up everything that now sits at the
    # root address: the W1..W5 sweep outputs from Step 1 plus the SDK
    # self-sweep output from Step 2. +import_wallet(include_unconfirmed:
    # true)+ scans WoC's +/unspent/all+ so the just-broadcast outputs
    # show up immediately (in mempool). +no_send: false+ broadcasts the
    # per-import Phase 2 self-payment, keeping the wallet's view
    # consistent with chain (every action carries a real txid).
    sdk[:engine].import_wallet(include_unconfirmed: true,
                               no_send: false,
                               accept_delayed_broadcast: false)
    sdk_final_balance = sdk[:utxo_pool].balance
    recovered = sdk_final_balance - sdk_starting_balance
    total_funded = test_ctxs.size * funding_per_wallet
    recovery_fraction = recovered.to_f / total_funded

    warn "\n=== Phase 4 cleanup summary ==="
    warn "  consolidation steps: #{consolidation_steps}"
    warn "  sweep tx:            #{sweep_count}"
    warn "  SDK balance:         #{sdk_starting_balance} → #{sdk_final_balance} (Δ #{recovered})"
    warn "  recovery fraction:   #{(recovery_fraction * 100).round(2)}%"
    warn "===\n"

    BSV::Wallet.emit('e2e.phase4.complete',
                     recovered: recovered,
                     recovery_fraction: recovery_fraction.round(4),
                     consolidation_steps: consolidation_steps,
                     sweep_tx: sweep_count)

    # Each Wn ends with zero spendable — the strict acceptance
    # criterion that consolidation + sweep removed everything.
    test_ctxs.each do |name, ctx|
      E2E::WalletHarness.activate(ctx)
      expect(ctx[:utxo_pool].spendable_count).to eq(0),
                                                 "#{name} still has #{ctx[:utxo_pool].spendable_count} spendable"
    end

    expect(recovery_fraction).to be >= recovery_floor_fraction,
                                 "recovered #{(recovery_fraction * 100).round(2)}% of funded balance " \
                                 "(floor: #{(recovery_floor_fraction * 100).round(2)}%)"
  end
end
