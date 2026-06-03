# frozen_string_literal: true

# E2E scenarios for HLR #251 — Arcade SSE push resolution.
#
# Eight live on-chain scenarios (E1–E8) that validate the SSE listener +
# the reshaped +Engine::Broadcast#submit+ pipeline end to end. Each example
# is +xit+ today; sub-issue #267 will flip them to +it+ in implementation
# order (E4 first — the load-bearing double-spend test that gates ADR §5).
#
# Distinct from +e2e_workload_spec.rb+ (the #126 ~10k-tx workload harness):
# these scenarios are scoped to SSE event correlation (bounded windows,
# explicit input selection via +inputs: [{ output_id: N }]+, no auto-fund),
# not sustained throughput. The two specs share the e2e support modules
# (+WalletHarness+, +DaemonSupervisor+, +EventLog+) and the same +E2E_MODE+
# safety gate.
#
# === Safety gate: E2E_MODE ===========================================
# These scenarios spend real mainnet sats. They are gated on +E2E_MODE+,
# defaulting to a clean skip:
#
#   unset / "skip"  → skipped (the default — env presence alone never
#                     triggers a live run).
#   "rehearse"      → every chain-touching send runs no_send: true, so
#                     nothing reaches ARC. The SSE-correlation assertions
#                     are inherently live-only; rehearse exercises only
#                     the consolidate/sweep precondition and the env gate.
#   "live"          → the real thing: on-chain broadcasts, SSE listener
#                     connected to arcade.gorillapool.io, bounded-window
#                     assertions on event arrival.
#
# Required env (same as +e2e_workload_spec.rb+ — see spec/e2e/README.md):
#   BSV_WALLET_WIF_SDK    — funding key (mandatory)
#   BSV_WALLET_POSTGRES   — Postgres base URL (mandatory)
#
# Implementation order (per #267): E4 first (double-spend, load-bearing).
# If E4 doesn't pass reliably, ADR §5's SSE-primary decision is
# invalidated and the HLR has to be revisited before the rest land.

require_relative 'spec_helper'

RSpec.describe 'e2e SSE broadcast scenarios' do # rubocop:disable RSpec/DescribeClass
  let(:mode) { (ENV['E2E_MODE'] || 'skip').downcase }

  def live?
    mode == 'live'
  end

  before do
    skip "scenarios gated on E2E_MODE (set to 'rehearse' or 'live'; got #{mode.inspect})" \
      unless %w[rehearse live].include?(mode)
    missing = E2E::WalletHarness.missing_env
    skip "scenarios require env: #{missing.join(', ')}" unless missing.empty?
  end

  # before(:all) consolidate/sweep — each scenario starts from a known
  # wallet state via the existing harness machinery (+Engine#sweep_to_root+
  # per plan §6.1). #267 will replace this stub with the real consolidate
  # + sweep against the test wallets, matching the stage-1 reset pattern
  # in +e2e_workload_spec.rb+.

  it 'E1 — basic send: fan-out SDK → W1..W5 surfaces 5 SEEN_ON_NETWORK frames within window' do
    skip '#267 — fan-out from SDK to W1..W5 (4 delayed + 1 inline); ' \
         'broadcast all 4 delayed via the Broadcaster path; assert SSE listener ' \
         'observes 5 SEEN_ON_NETWORK events within bounded window. (Plan §6.4 E1.)'
  end

  it 'E2 — parent + child: SSE observes both SEEN within window, in arrival order' do
    skip '#267 — two actions with explicit inputs: [{ output_id }] selecting known ' \
         'UTXOs (not auto-fund); broadcast parent then child; assert SSE observes ' \
         'both SEEN within window, in arrival order. (Plan §6.4 E2.)'
  end

  it 'E3 — long chain: 10-deep chain, SSE observes SEEN for tx 1–9 (10 is inline)' do
    skip '#267 — 10-deep chain with explicit inputs at each step; broadcast in ' \
         'order; assert SSE observes events for tx 1–9 (10 is inline). ' \
         'Listener throughput sanity. (Plan §6.4 E3.)'
  end

  it 'E4 — double-spend (LOAD-BEARING): SSE delivers REJECTED for the loser within window' do
    skip '#267 — pre-broadcast Action 3 (spends output A); then attempt ' \
         'broadcast(Action 1) which also spends A; assert SSE delivers REJECTED ' \
         '(or DOUBLE_SPEND_ATTEMPTED) for Action 1 within window. If this does ' \
         "not pass reliably, ADR §5's SSE-primary decision is invalidated. " \
         '(Plan §6.4 E4; implement first per #267.)'
  end

  it 'E5 — reconnect during flight: catchup delivers the (current-status) frame' do
    skip '#267 — broadcast a tx; kill listener before its SEEN frame arrives; ' \
         'wait for the frame to have been emitted server-side; restart listener ' \
         'with cursor; assert catchup delivers the (current-status) frame. ' \
         '(Plan §6.4 E5.)'
  end

  it 'E6 — long-lived connection: keepalive holds across idle minutes' do
    skip '#267 — open listener, idle for N minutes (configurable, default 5), ' \
         "broadcast a tx, assert keepalive didn't drop the connection and the " \
         'event arrives. Guards against silent connection death. (Plan §6.4 E6.)'
  end

  it 'E7 — double-spend timing race: exactly one SEEN + one REJECTED' do
    skip "#267 — broadcast Action A and conflicting Action A' in tight succession; " \
         'one wins, one is REJECTED; assert exactly one SEEN and one REJECTED ' \
         'arrive. (Plan §6.4 E7.)'
  end

  it 'E8 — reject reason granularity capture: document Arcade rejected-frame txStatus' do
    skip "#267 — capture the rejected frame's txStatus for the double-spend case; " \
         'document what Arcade actually emits (REJECTED vs DOUBLE_SPEND_ATTEMPTED). ' \
         'Closes the ADR §5 open item with concrete evidence. (Plan §6.4 E8.)'
  end
end
