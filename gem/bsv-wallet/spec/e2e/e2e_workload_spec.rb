# frozen_string_literal: true

# The #126 e2e on-chain harness — one self-contained test.
#
# Earlier iterations split this into four "phase" specs (setup,
# fragmentation, broadcast, cleanup). Three of those were really
# *machinery* — drain/fund, the no_send fanout cascade, and the sweep
# back to root — exercised in isolation by other suites already:
#   - Fanout cascade  → spec/integration/stress_cascade_spec.rb (#129)
#   - consolidate/sweep → rake wallet:cleanup + Engine#sweep_to_root specs
# So the harness no longer carries them as separate phase-specs. It is
# the on-chain *broadcast workload*; the reset/fund/fanout stages are
# preconditions it builds inline from the same Engine machinery.
#
# Stages (one example, run in order):
#
#   1. Reset / consolidate  [assert]
#      Sweep every test wallet back to the SDK root (Engine#sweep_to_root
#      — consolidate_step loop + terminal sweep) so a prior aborted run's
#      residue drains cleanly; no-op when the wallet is empty.
#      Assert: each Wn has zero spendable; the SDK's *on-chain* root
#      balance (read from WoC, not the DB — the blank-slate sweep leaves
#      the SDK DB empty by design) covers the total funding.
#
#   2. Fund (SDK → Wn, on-chain)
#      SDK first imports its swept root balance under management, then
#      pays each test wallet +FUND_SATS+ (no_send mirrors the run mode —
#      live broadcasts, rehearse does not). The recipient internalizes
#      the BEEF. Each Wn now holds one clean UTXO whose proofs reach
#      confirmed ancestors — the precondition for the no_send fanout's
#      BEEFs to verify SPV at the recipient.
#
#   3. Fanout  [assert]
#      A 5-level no_send cascade across the five wallets via the shared
#      Fanout.pass primitive — nothing reaches ARC, BEEF handed peer to
#      peer. Builds the fragmented spendable set the broadcast loop draws
#      from. Assert: each wallet at or above FANOUT_MIN_SPENDABLE, and
#      outbound action count == inbound (every send internalized once).
#
#   4. Broadcast
#      Drives ~10_000 on-chain transactions over ~1 hour to surface:
#        - Stale-BEEF behaviour (rate, outcome) — logged, not remediated.
#          The daemon's proof-acquisition loop refreshes proofs in the
#          background; rejects are recorded and the broadcast retries
#          naturally on the next cycle.
#        - Block-boundary continuity across ≥3 mined blocks.
#        - Sustained throughput against multi-provider ARC routing.
#      Pattern: 400 cycles × 25 tx every 9s (absolute interval) ≈ 10k tx.
#      Sender + recipient random (not-self). Amount drawn from
#      clamp(round(Normal(5000, 1000)), 1000, 9000). One walletd
#      subprocess per wallet runs for the duration so proof-acquisition
#      keeps the proof_store current.
#      Termination: at least +BROADCAST_MIN_TX+ accepted AND at least
#      +BROADCAST_MIN_BLOCKS+ blocks mined since the loop started — both
#      must hold simultaneously.
#
# No end-of-run cleanup: stage 1 of the *next* run drains whatever this
# run leaves behind. An aborted run can be recovered standalone with
# `rake wallet:cleanup[wN]` per wallet.
#
# === Safety gate: E2E_MODE ===========================================
# This harness spends real mainnet sats. To stop it firing live by
# accident it is gated on E2E_MODE, defaulting to a clean skip:
#
#   unset / "skip"  → skipped (the default — env presence alone never
#                     triggers a live run).
#   "rehearse"      → every chain-touching send runs no_send: true, so
#                     nothing reaches ARC. Proves the full plumbing and
#                     all stage asserts without broadcasting. Skips the
#                     walletd supervisor and the block-height gate (no
#                     real txs → no blocks to wait for).
#   "live"          → the real thing: on-chain broadcasts, walletd
#                     subprocesses, block-boundary termination.
#
# Smoke test (rehearse, tiny, ~seconds — proves all four stages wire up).
# Requires the six test DBs to be empty (drop+create them, or use a fresh
# BSV_WALLET_POSTGRES base) — the post-fanout assertion counts rows.
#   E2E_MODE=rehearse FUND_SATS=100000 \
#     FANOUT_L4_PAYMENTS=10 FANOUT_L5_PAYMENTS=10 \
#     FANOUT_L4_SATS=2000 FANOUT_L5_SATS=500 FANOUT_MIN_SPENDABLE=20 \
#     BROADCAST_CYCLES=5 BROADCAST_PER_CYCLE=5 BROADCAST_MIN_TX=10 \
#     BROADCAST_MIN_BLOCKS=0 bundle exec rspec spec/e2e/e2e_workload_spec.rb
#
# Tunables for dev iteration:
#   E2E_MODE                (default skip; rehearse | live)
#   RESET_TARGET_INPUTS     (default 20)
#   FUND_SATS               (default 10_000_000)
#   FANOUT_L4_PAYMENTS      (default 73) / FANOUT_L5_PAYMENTS (default 73)
#   FANOUT_L4_SATS          (default 50_000) / FANOUT_L5_SATS (default 12_000)
#   FANOUT_MIN_SPENDABLE    (default 500)
#   BROADCAST_CYCLES        (default 400)
#   BROADCAST_PER_CYCLE     (default 25)
#   BROADCAST_INTERVAL_S    (default 9)
#   BROADCAST_MIN_TX        (default 10_000)
#   BROADCAST_MIN_BLOCKS    (default 3)
#   BROADCAST_AMOUNT_MEAN   (default 5000) / BROADCAST_AMOUNT_SD (default 1000)
#   BROADCAST_AMOUNT_MIN    (default 1000) / BROADCAST_AMOUNT_MAX (default 9000)

require_relative 'spec_helper'
require_relative '../support/fanout'

RSpec.describe 'e2e on-chain harness' do # rubocop:disable RSpec/DescribeClass
  let(:mode)            { (ENV['E2E_MODE'] || 'skip').downcase }
  let(:target_inputs)   { (ENV['RESET_TARGET_INPUTS'] || 20).to_i }
  let(:fund_satoshis)   { (ENV['FUND_SATS'] || 10_000_000).to_i }
  let(:l4_payments)     { (ENV['FANOUT_L4_PAYMENTS'] || 73).to_i }
  let(:l5_payments)     { (ENV['FANOUT_L5_PAYMENTS'] || 73).to_i }
  let(:l4_satoshis)     { (ENV['FANOUT_L4_SATS'] || 50_000).to_i }
  let(:l5_satoshis)     { (ENV['FANOUT_L5_SATS'] || 12_000).to_i }
  let(:fanout_min_spendable) { (ENV['FANOUT_MIN_SPENDABLE'] || 500).to_i }
  let(:cycles)          { (ENV['BROADCAST_CYCLES']     || 400).to_i }
  let(:per_cycle)       { (ENV['BROADCAST_PER_CYCLE']  || 25).to_i }
  let(:interval_s)      { (ENV['BROADCAST_INTERVAL_S'] || 9).to_i }
  let(:min_tx)          { (ENV['BROADCAST_MIN_TX']     || 10_000).to_i }
  let(:min_blocks)      { (ENV['BROADCAST_MIN_BLOCKS'] || 3).to_i }
  let(:amount_mean)     { (ENV['BROADCAST_AMOUNT_MEAN'] || 5000).to_i }
  let(:amount_sd)       { (ENV['BROADCAST_AMOUNT_SD']   || 1000).to_i }
  let(:amount_min)      { (ENV['BROADCAST_AMOUNT_MIN']  || 1000).to_i }
  let(:amount_max)      { (ENV['BROADCAST_AMOUNT_MAX']  || 9000).to_i }
  let(:received_basket) { 'received' }

  # live?  → real on-chain broadcasts. rehearse forces no_send on every
  # send so nothing reaches ARC (see the E2E_MODE gate in the header).
  def live?
    mode == 'live'
  end

  before do
    skip "harness gated on E2E_MODE (set to 'rehearse' or 'live'; got #{mode.inspect})" \
      unless %w[rehearse live].include?(mode)
    missing = E2E::WalletHarness.missing_env
    skip "harness requires env: #{missing.join(', ')}" unless missing.empty?
    E2E::EventLog.start
  end

  after { E2E::EventLog.stop }

  # ---- helpers ------------------------------------------------------

  # Clamped normal-distribution amount per HLR §Broadcast Timing.
  # Box-Muller — cheap, no dependency. Two uniforms → one normal.
  def random_amount
    # 1.0 - rand keeps u1 in (0, 1] — rand can return 0.0, and Math.log(0)
    # is -Infinity, which would make the rounded amount raise FloatDomainError.
    u1 = 1.0 - rand
    u2 = rand
    z = Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math::PI * u2)
    (amount_mean + (z * amount_sd)).round.clamp(amount_min, amount_max)
  end

  # Internalize an SDK funding payment at the recipient: 'wallet payment'
  # protocol with payment_remittance, matching bin/receive's funding path.
  def internalize_funding(recipient_ctx, payment, description:)
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
      description: description
    )
  end

  # Internalize a peer payment at the recipient: 'basket insertion' into
  # +received_basket+ with BRC-42 derivation context — the fanout and
  # broadcast handoff shape used by the CI cascade specs and bin/receive.
  def internalize_received(recipient_ctx, payment, description:)
    recipient_ctx[:engine].internalize_action(
      tx: payment[:beef],
      outputs: payment[:outputs].map do |o|
        {
          output_index: o[:vout], satoshis: o[:satoshis],
          protocol: 'basket insertion',
          insertion_remittance: {
            basket: received_basket,
            derivation_prefix: o[:derivation_prefix],
            derivation_suffix: o[:derivation_suffix],
            sender_identity_key: payment[:sender_identity_key]
          }
        }
      end,
      description: description
    )
  end

  # Stage 1 — drain one test wallet's tracked balance back to the SDK
  # root. import_wallet first picks up any untracked balance sitting at
  # the root address (a partial prior run); sweep_to_root then
  # consolidates the tracked spendable set down to < target_inputs and
  # sweeps the remainder to the SDK root P2PKH on chain. Returns the
  # sweep_to_root result.
  def drain_to_sdk(ctx, sdk_identity:)
    E2E::WalletHarness.activate(ctx)
    begin
      ctx[:engine].import_wallet
    rescue StandardError => e
      BSV::Wallet.emit('e2e.reset.import.failed', error: e.message.lines.first&.chomp)
    end
    ctx[:engine].sweep_to_root(recipient: sdk_identity, target_inputs: target_inputs)
  end

  # Stage 1 precondition — the SDK's *on-chain* spendable balance at its
  # root P2PKH, read straight from WoC. The blank-slate sweep leaves the
  # SDK DB empty by design (funds SAFU on chain, recoverable from the
  # bare WIF), so the DB spendable count is 0 and tells us nothing about
  # whether the SDK can fund the run. Query the chain instead — this is
  # read-only, it does NOT import or otherwise commit to the UTXOs.
  def sdk_root_chain_balance(sdk)
    address = sdk[:key_deriver].root_private_key.public_key.address
    response = sdk[:engine].services.call(:get_utxos_all, address)
    Array(response&.data).sum { |u| u['value'].to_i }
  end

  # Stage 2 — SDK pays fund_satoshis to recipient_ctx on chain; the
  # recipient internalizes the BEEF. Returns the funding dtxid.
  def fund_wallet(sdk:, recipient_ctx:)
    E2E::WalletHarness.activate(sdk)
    payment = sdk[:engine].send_payment(
      recipient: recipient_ctx[:key_deriver].identity_key,
      satoshis: fund_satoshis,
      no_send: !live?, accept_delayed_broadcast: false
    )

    E2E::WalletHarness.activate(recipient_ctx)
    internalize_funding(recipient_ctx, payment, description: 'harness funding from SDK')

    dtxid = payment[:txid].reverse.unpack1('H*')
    BSV::Wallet.emit('e2e.fund', dtxid: dtxid,
                                 wallet: recipient_ctx[:key_deriver].identity_key[0..8],
                                 satoshis: fund_satoshis)
    dtxid
  end

  # Stage 3 — one no_send fanout pass over +ctxs+: each wallet sends
  # +count+ payments of +satoshis+ to a random not-self peer, BEEF
  # internalized at the recipient. +level+ labels the cascade tier.
  # Returns the per-route count Hash.
  def fanout_pass!(ctxs, count:, satoshis:, level:)
    Fanout.pass(wallets: ctxs.keys, count: count, satoshis: satoshis) do |sender, recipient, sats, i|
      E2E::WalletHarness.activate(ctxs[sender])
      payment = ctxs[sender][:engine].send_payment(
        recipient: ctxs[recipient][:key_deriver].identity_key,
        satoshis: sats
        # no_send: true is the default — see Engine#send_payment.
      )
      E2E::WalletHarness.activate(ctxs[recipient])
      internalize_received(ctxs[recipient], payment, description: "#{level} fragment")
      BSV::Wallet.emit("e2e.fanout.#{level}",
                       from: sender, to: recipient, satoshis: sats, i: i + 1)
    end
  end

  # Stage 4 — drive one inline-broadcast payment. Returns :accepted on
  # success, :failed on any exception (logged with class + message head;
  # categorisation by post-processing the event log).
  def drive_one_payment(ctxs, names)
    sender = names.sample
    recipient = (names - [sender]).sample
    amount = random_amount
    sender_ctx = ctxs[sender]
    recipient_ctx = ctxs[recipient]

    begin
      E2E::WalletHarness.activate(sender_ctx)
      payment = sender_ctx[:engine].send_payment(
        recipient: recipient_ctx[:key_deriver].identity_key,
        satoshis: amount,
        no_send: !live?, accept_delayed_broadcast: false
      )
      E2E::WalletHarness.activate(recipient_ctx)
      internalize_received(recipient_ctx, payment, description: 'broadcast payment')
      dtxid = payment[:txid].reverse.unpack1('H*')
      BSV::Wallet.emit('e2e.bcast.accepted',
                       from: sender, to: recipient, satoshis: amount, dtxid: dtxid)
      :accepted
    rescue StandardError => e
      BSV::Wallet.emit('e2e.bcast.failed',
                       from: sender, to: recipient, satoshis: amount,
                       error_class: e.class.name,
                       error: e.message.lines.first&.chomp&.slice(0, 200))
      :failed
    end
  end

  def current_block_height(chain_services)
    response = chain_services.call(:current_height)
    response&.data.to_i
  rescue StandardError => e
    BSV::Wallet.emit('e2e.bcast.height.failed', error: e.message.lines.first&.chomp)
    0
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # ---- the test -----------------------------------------------------

  it 'resets, funds, fragments, then sustains ~10k broadcasts across ≥3 blocks' do
    # Boot in-process engines: the funding wallet (sdk) and the five
    # derived test wallets (w1..w5).
    E2E::WalletHarness.install_derived_wifs!
    sdk = E2E::WalletHarness.boot('sdk')
    sdk_identity = sdk[:key_deriver].identity_key
    test_ctxs = E2E::WalletHarness.test_wallet_names.to_h do |name|
      [name, E2E::WalletHarness.boot(name)]
    end
    names = E2E::WalletHarness.test_wallet_names

    # === Stage 1 — reset / consolidate ==============================
    BSV::Wallet.emit('e2e.reset.start', target_inputs: target_inputs,
                                        wallets: names.join(','))
    test_ctxs.each do |name, ctx|
      result = drain_to_sdk(ctx, sdk_identity: sdk_identity)
      dtxid = result[:sweep] && result[:sweep][:txid].reverse.unpack1('H*')
      BSV::Wallet.emit('e2e.reset.drain', wallet: name,
                                          consolidation_steps: result[:consolidation_steps],
                                          dtxid: dtxid, swept: !dtxid.nil?)
    rescue StandardError => e
      BSV::Wallet.emit('e2e.reset.drain.failed', wallet: name,
                                                 error: e.message.lines.first&.chomp)
    end

    # Precondition is the SDK's *on-chain* balance, not its DB balance.
    # The blank-slate sweep leaves the SDK DB empty by design — funds are
    # SAFU on chain at the root P2PKH, not tracked as spendable. Query WoC
    # (read-only, no import) to confirm the SDK can fund the run.
    E2E::WalletHarness.activate(sdk)
    sdk_chain_balance = sdk_root_chain_balance(sdk)
    total_funding = names.size * fund_satoshis
    BSV::Wallet.emit('e2e.reset.complete', sdk_chain_balance: sdk_chain_balance,
                                           total_funding: total_funding)

    test_ctxs.each do |name, ctx|
      E2E::WalletHarness.activate(ctx)
      expect(ctx[:utxo_pool].spendable_count).to eq(0),
                                                 "#{name} still has #{ctx[:utxo_pool].spendable_count} spendable after reset"
    end
    expect(sdk_chain_balance).to be >= total_funding,
                                 "SDK on-chain balance #{sdk_chain_balance} < required funding #{total_funding}"

    # === Stage 2 — fund each test wallet from SDK (on-chain) ========
    # SDK pulls its swept root balance under management before spending.
    # include_unconfirmed so a just-swept mempool output is visible;
    # no_send mirrors the run mode (rehearse never broadcasts the
    # per-import BRC-42 self-payment).
    E2E::WalletHarness.activate(sdk)
    sdk[:engine].import_wallet(include_unconfirmed: true,
                               no_send: !live?, accept_delayed_broadcast: false)

    funding_dtxids = test_ctxs.each_with_object({}) do |(name, ctx), acc|
      acc[name] = fund_wallet(sdk: sdk, recipient_ctx: ctx)
    end
    BSV::Wallet.emit('e2e.fund.complete', funded: funding_dtxids.size)

    test_ctxs.each do |name, ctx|
      E2E::WalletHarness.activate(ctx)
      expect(ctx[:utxo_pool].balance).to eq(fund_satoshis),
                                         "#{name}: balance #{ctx[:utxo_pool].balance} != #{fund_satoshis}"
    end

    # === Stage 3 — no_send fanout cascade ===========================
    BSV::Wallet.emit('e2e.fanout.start',
                     l4_payments: l4_payments, l4_satoshis: l4_satoshis,
                     l5_payments: l5_payments, l5_satoshis: l5_satoshis)
    l4_log = fanout_pass!(test_ctxs, count: l4_payments, satoshis: l4_satoshis, level: 'l4')
    l5_log = fanout_pass!(test_ctxs, count: l5_payments, satoshis: l5_satoshis, level: 'l5')

    fanout_state = test_ctxs.to_h do |name, ctx|
      out_db = Sequel.connect(ENV.fetch("DATABASE_URL_#{name.upcase}"))
      begin
        actions = {
          outbound: out_db[:actions].where(Sequel.like(:description, 'send %')).count,
          inbound: out_db[:actions].where(Sequel.like(:description, '% fragment')).count
        }
      ensure
        out_db.disconnect
      end
      E2E::WalletHarness.activate(ctx)
      [name, { spendable_count: ctx[:utxo_pool].spendable_count, actions: actions }]
    end

    warn "\n=== Fanout summary ==="
    warn "  L4 routes: #{l4_log.sort.map { |r, n| "#{r}=#{n}" }.join(' ')}"
    warn "  L5 routes: #{l5_log.sort.map { |r, n| "#{r}=#{n}" }.join(' ')}"
    fanout_state.each do |w, s|
      warn "  #{w}: spendable=#{s[:spendable_count]} out=#{s[:actions][:outbound]} in=#{s[:actions][:inbound]}"
    end
    warn "===\n"
    BSV::Wallet.emit('e2e.fanout.complete',
                     total_spendable: fanout_state.values.sum { |s| s[:spendable_count] })

    expected_outbound = l4_payments + l5_payments
    fanout_state.each do |w, s|
      expect(s[:actions][:outbound]).to eq(expected_outbound),
                                        "#{w}: #{s[:actions][:outbound]} outbound actions (expected #{expected_outbound})"
      expect(s[:spendable_count]).to be >= fanout_min_spendable,
                                     "#{w}: only #{s[:spendable_count]} spendable after fanout (min #{fanout_min_spendable})"
    end
    total_outbound = fanout_state.values.sum { |s| s[:actions][:outbound] }
    total_inbound  = fanout_state.values.sum { |s| s[:actions][:inbound] }
    expect(total_outbound).to eq(total_inbound),
                              "outbound=#{total_outbound} != inbound=#{total_inbound} (BEEF handoff lost)"

    # === Stage 4 — broadcast workload ===============================
    # Spawn a walletd subprocess per wallet so proof-acquisition runs in
    # the background while the harness pushes broadcasts. stop_all relies
    # on Scheduler#shutdown (#233) for cooperative drain. Rehearse never
    # broadcasts, so there are no proofs to acquire — skip the daemons and
    # the block-height gate (effective_min_blocks 0; no real txs → no
    # blocks to wait for).
    supervisor = nil
    if live?
      supervisor = E2E::DaemonSupervisor.new(wallet_names: names, network: :mainnet)
      supervisor.start_all
      BSV::Wallet.emit('e2e.daemons.up', count: supervisor.log_paths.size)
    end
    effective_min_blocks = live? ? min_blocks : 0

    # Any wallet's Engine#services serves the chain-height query —
    # affinity is irrelevant for current_height (no per-tx caching) and
    # it inherits the same provider order as the broadcast path.
    chain_services = test_ctxs.values.first[:engine].services
    starting_height = current_block_height(chain_services)
    BSV::Wallet.emit('e2e.broadcast.start',
                     starting_height: starting_height,
                     cycles: cycles, per_cycle: per_cycle, interval_s: interval_s)

    accepted = 0
    failed = 0
    cycle_completed = 0
    current_height = starting_height

    begin
      cycles.times do |cycle_idx|
        next_cycle_at = monotonic_now + interval_s

        per_cycle.times do
          outcome = drive_one_payment(test_ctxs, names)
          outcome == :accepted ? accepted += 1 : failed += 1
        end

        current_height = current_block_height(chain_services)
        cycle_completed = cycle_idx + 1
        BSV::Wallet.emit('e2e.broadcast.cycle',
                         n: cycle_completed, accepted: accepted, failed: failed,
                         height: current_height,
                         blocks_mined: current_height - starting_height)

        # Termination — both conditions must hold per HLR. In rehearse
        # effective_min_blocks is 0, so the block condition is vacuously
        # met and the loop terminates on accepted count alone.
        if accepted >= min_tx && (current_height - starting_height) >= effective_min_blocks
          BSV::Wallet.emit('e2e.broadcast.termination',
                           reason: 'min_tx_and_min_blocks_met',
                           accepted: accepted, blocks_mined: current_height - starting_height)
          break
        end

        wait_s = next_cycle_at - monotonic_now
        sleep wait_s if wait_s.positive?
      end
    ensure
      if supervisor
        drain_results = supervisor.stop_all
        BSV::Wallet.emit('e2e.daemons.down',
                         drained: drain_results.values.count(:drained),
                         killed: drain_results.values.count(:killed))
      end
    end

    blocks_mined = current_height - starting_height
    warn "\n=== Broadcast summary ==="
    warn "  cycles completed: #{cycle_completed} / #{cycles}"
    warn "  accepted: #{accepted}  failed: #{failed}"
    warn "  blocks: #{starting_height} → #{current_height} (Δ #{blocks_mined})"
    warn "===\n"
    BSV::Wallet.emit('e2e.broadcast.complete',
                     accepted: accepted, failed: failed,
                     blocks_mined: blocks_mined, cycles_completed: cycle_completed)

    expect(accepted).to be >= min_tx,
                        "only #{accepted} accepted broadcasts (expected >= #{min_tx})"
    # Block-boundary continuity is a live-only assertion — rehearse never
    # broadcasts, so no blocks are mined by this run.
    if live?
      expect(blocks_mined).to be >= min_blocks,
                              "only #{blocks_mined} blocks mined (expected >= #{min_blocks})"
    end
  end
end
