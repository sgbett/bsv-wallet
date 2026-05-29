# frozen_string_literal: true

# Phase 4 of the #126 e2e on-chain harness — sweep back to SDK.
#
# Restores each test wallet to zero spendable by:
#   1. Looping +consolidate_step+ until the wallet has < 20 spendable
#      outputs. Each step broadcasts on chain (no_send: false,
#      accept_delayed_broadcast: false). The 20-smallest + 1-largest
#      input shape ensures fee coverage even when the smallest are
#      below the per-input marginal fee.
#   2. Running +sweep+ to send the remaining balance to the SDK
#      identity_key (also broadcast on chain). SDK best-effort
#      internalizes each sweep BEEF so SDK's view reflects the
#      inbound; +import_wallet+ rescan catches anything internalize
#      couldn't wire.
#
# No block-confirmation wait — synchronous broadcast acceptance is
# the success signal. The daemon's TxProof loop attaches proofs
# later in the background; the Wn→zero-spendable assertion and the
# recovery-floor assertion both read state available immediately
# after broadcast.
#
# Restart-safe per HLR: running this phase standalone restores the
# wallets to a state where a fresh Phase 1 can begin. If invoked
# without a preceding run, it does no harm — consolidate_step
# returns nil immediately when the wallet has no spendable outputs.

require_relative 'spec_helper'

RSpec.describe 'e2e Phase 4 — consolidate + sweep to SDK' do # rubocop:disable RSpec/DescribeClass
  let(:target_inputs)           { (ENV['CLEANUP_TARGET_INPUTS']  || 20).to_i }
  let(:max_consolidation_steps) { (ENV['CLEANUP_MAX_STEPS']      || 200).to_i }
  let(:recovery_floor_fraction) { (ENV['CLEANUP_RECOVERY_FLOOR']  || 0.95).to_f }
  let(:funding_per_wallet)      { (ENV['CLEANUP_FUND_PER_WALLET'] || 10_000_000).to_i }

  before do
    missing = E2E::WalletHarness.missing_env
    skip "Phase 4 requires env: #{missing.join(', ')}" unless missing.empty?
    E2E::EventLog.start
  end

  after { E2E::EventLog.stop }

  def internalize_at_sdk(sdk_ctx, payment, description:)
    sdk_ctx[:engine].internalize_action(
      tx: payment[:tx],
      outputs: [
        {
          output_index: 0,
          protocol: 'wallet payment',
          payment_remittance: {
            # sweep + consolidate use a self-derived destination key,
            # not the sender's identity_key — but SDK still needs the
            # derivation context to spend later. The +sweep+ caller
            # picked the BRC-42 +derivation_prefix+ randomly; we don't
            # have access to it here from the +create_action+ result
            # shape. Best-effort internalize — +import_wallet+ rescan
            # catches anything this can't wire.
          }
        }
      ],
      description: description
    )
  rescue StandardError => e
    BSV::Wallet.emit('e2e.cleanup.internalize.failed',
                     error: e.message.lines.first&.chomp&.slice(0, 200))
  end

  # Loop consolidate_step on +ctx+ until the wallet has fewer than
  # +target_inputs+ spendable outputs OR +max_consolidation_steps+
  # iterations elapse (safety bound — protects against any
  # infinite-loop bug in selection / dust handling).
  #
  # Each step is broadcast on chain. Returns the array of dtxids
  # for the summary report.
  def consolidate_until_below_target(name, ctx)
    E2E::WalletHarness.activate(ctx)
    dtxids = []
    max_consolidation_steps.times do |i|
      result = ctx[:engine].consolidate_step(
        target_inputs: target_inputs,
        no_send: false, accept_delayed_broadcast: false
      )
      break if result.nil?

      dtxid = result[:txid].reverse.unpack1('H*')
      dtxids << dtxid
      BSV::Wallet.emit('e2e.cleanup.consolidate',
                       wallet: name, step: i + 1, dtxid: dtxid,
                       remaining: ctx[:utxo_pool].spendable_count)
    end
    dtxids
  end

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

    # Step 1 — consolidate each Wn down to < target_inputs spendable.
    consolidation_dtxids = test_ctxs.flat_map do |name, ctx|
      consolidate_until_below_target(name, ctx)
    end

    # Step 2 — sweep each Wn's remaining balance to the SDK identity.
    sweep_dtxids = test_ctxs.filter_map do |name, ctx|
      E2E::WalletHarness.activate(ctx)
      sweep_result = ctx[:engine].sweep(
        recipient: sdk_identity,
        no_send: false, accept_delayed_broadcast: false
      )
      if sweep_result.nil?
        BSV::Wallet.emit('e2e.cleanup.sweep.skipped', wallet: name, reason: 'no_spendable')
        next nil
      end

      dtxid = sweep_result[:txid].reverse.unpack1('H*')
      BSV::Wallet.emit('e2e.cleanup.sweep', wallet: name, dtxid: dtxid)

      # Best-effort SDK-side internalize so SDK's view of balance
      # reflects the inbound. If the +sweep+ result doesn't carry the
      # derivation context needed by +internalize_action+, +import_wallet+
      # below picks up the root-key-owned outputs.
      E2E::WalletHarness.activate(sdk)
      internalize_at_sdk(sdk, sweep_result, description: "phase 4 sweep from #{name}")
      dtxid
    end

    # Step 3 — re-scan SDK for inbound to catch anything internalize
    # couldn't wire. Does not wait for confirmation; +get_utxos+
    # against unconfirmed inbound may return nothing yet, which the
    # recovery-floor assertion can interpret accordingly.
    E2E::WalletHarness.activate(sdk)
    sdk[:engine].import_wallet
    sdk_final_balance = sdk[:utxo_pool].balance
    recovered = sdk_final_balance - sdk_starting_balance
    total_funded = test_ctxs.size * funding_per_wallet
    recovery_fraction = recovered.to_f / total_funded

    warn "\n=== Phase 4 cleanup summary ==="
    warn "  consolidation steps: #{consolidation_dtxids.length}"
    warn "  sweep tx:            #{sweep_dtxids.length}"
    warn "  SDK balance:         #{sdk_starting_balance} → #{sdk_final_balance} (Δ #{recovered})"
    warn "  recovery fraction:   #{(recovery_fraction * 100).round(2)}%"
    warn "===\n"

    BSV::Wallet.emit('e2e.phase4.complete',
                     recovered: recovered,
                     recovery_fraction: recovery_fraction.round(4),
                     consolidation_steps: consolidation_dtxids.length,
                     sweep_tx: sweep_dtxids.length)

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
