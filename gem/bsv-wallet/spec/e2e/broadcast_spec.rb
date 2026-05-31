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
#      residue drains cleanly; no-op when the wallet is empty. SDK then
#      rescans its root to pull the swept balance back under management.
#      Assert: each Wn has zero spendable; SDK holds enough to fund.
#
#   2. Fund (SDK → Wn, on-chain)
#      SDK pays each test wallet +FUND_SATS+ with no_send: false so the
#      funding output's ancestry is confirmed on chain. The recipient
#      internalizes the BEEF. Each Wn now holds one clean UTXO whose
#      proofs reach confirmed ancestors — the precondition for the
#      no_send fanout's BEEFs to verify SPV at the recipient.
#
#   3. Fanout  [assert]
#      A 5-level no_send cascade across the five wallets via the shared
#      Fanout.pass primitive — nothing reaches ARC, BEEF handed peer to
#      peer. Builds the fragmented spendable set the broadcast loop draws
#      from. Assert: each wallet well over the 500-output baseline, and
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
# Tunables for dev iteration:
#   RESET_TARGET_INPUTS     (default 20)
#   FUND_SATS               (default 10_000_000)
#   FANOUT_L4_PAYMENTS      (default 73) / FANOUT_L5_PAYMENTS (default 73)
#   FANOUT_L4_SATS          (default 50_000) / FANOUT_L5_SATS (default 12_000)
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
  let(:target_inputs)   { (ENV['RESET_TARGET_INPUTS'] || 20).to_i }
  let(:fund_satoshis)   { (ENV['FUND_SATS'] || 10_000_000).to_i }
  let(:l4_payments)     { (ENV['FANOUT_L4_PAYMENTS'] || 73).to_i }
  let(:l5_payments)     { (ENV['FANOUT_L5_PAYMENTS'] || 73).to_i }
  let(:l4_satoshis)     { (ENV['FANOUT_L4_SATS'] || 50_000).to_i }
  let(:l5_satoshis)     { (ENV['FANOUT_L5_SATS'] || 12_000).to_i }
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

  before do
    missing = E2E::WalletHarness.missing_env
    skip "harness requires env: #{missing.join(', ')}" unless missing.empty?
    E2E::EventLog.start
  end

  after { E2E::EventLog.stop }

  # ---- helpers ------------------------------------------------------

  # Clamped normal-distribution amount per HLR §Broadcast Timing.
  # Box-Muller — cheap, no dependency. Two uniforms → one normal.
  def random_amount
    u1 = rand
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

  # Stage 2 — SDK pays fund_satoshis to recipient_ctx on chain; the
  # recipient internalizes the BEEF. Returns the funding dtxid.
  def fund_wallet(sdk:, recipient_ctx:)
    E2E::WalletHarness.activate(sdk)
    payment = sdk[:engine].send_payment(
      recipient: recipient_ctx[:key_deriver].identity_key,
      satoshis: fund_satoshis,
      no_send: false, accept_delayed_broadcast: false
    )

    E2E::WalletHarness.activate(recipient_ctx)
    internalize_funding(recipient_ctx, payment, description: 'harness funding from SDK')

    dtxid = payment[:beef][-32..].reverse.unpack1('H*')
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
        no_send: false, accept_delayed_broadcast: false
      )
      E2E::WalletHarness.activate(recipient_ctx)
      internalize_received(recipient_ctx, payment, description: 'broadcast payment')
      dtxid = payment[:beef][-32..].reverse.unpack1('H*')
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

    # SDK rescans its root to pull the just-swept balance (plus any
    # pre-existing root balance) back under management. include_unconfirmed
    # so the mempool sweep outputs show up immediately; no_send: false so
    # the per-import BRC-42 self-payment broadcasts and keeps SDK's view
    # consistent with chain.
    E2E::WalletHarness.activate(sdk)
    sdk[:engine].import_wallet(include_unconfirmed: true,
                               no_send: false, accept_delayed_broadcast: false)
    sdk_balance = sdk[:utxo_pool].balance
    total_funding = names.size * fund_satoshis
    BSV::Wallet.emit('e2e.reset.complete', sdk_balance: sdk_balance,
                                           total_funding: total_funding)

    test_ctxs.each do |name, ctx|
      E2E::WalletHarness.activate(ctx)
      expect(ctx[:utxo_pool].spendable_count).to eq(0),
                                                 "#{name} still has #{ctx[:utxo_pool].spendable_count} spendable after reset"
    end
    expect(sdk_balance).to be >= total_funding,
                           "SDK balance #{sdk_balance} < required funding #{total_funding}"

    # === Stage 2 — fund each test wallet from SDK (on-chain) ========
    funding_dtxids = test_ctxs.each_with_object({}) do |(name, ctx), acc|
      acc[name] = fund_wallet(sdk: sdk, recipient_ctx: ctx)
    end
    BSV::Wallet.emit('e2e.fund.complete', funded: funding_dtxids.size)

    test_ctxs.each do |name, ctx|
      E2E::WalletHarness.activate(ctx)
      expect(ctx[:utxo_pool].balance).to be >= fund_satoshis - 200,
                                         "#{name}: balance #{ctx[:utxo_pool].balance} < #{fund_satoshis - 200}"
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
      expect(s[:spendable_count]).to be >= 500,
                                     "#{w}: only #{s[:spendable_count]} spendable after fanout"
    end
    total_outbound = fanout_state.values.sum { |s| s[:actions][:outbound] }
    total_inbound  = fanout_state.values.sum { |s| s[:actions][:inbound] }
    expect(total_outbound).to eq(total_inbound),
                              "outbound=#{total_outbound} != inbound=#{total_inbound} (BEEF handoff lost)"

    # === Stage 4 — broadcast workload ===============================
    # Spawn a walletd subprocess per wallet so proof-acquisition runs in
    # the background while the harness pushes broadcasts. stop_all relies
    # on Scheduler#shutdown (#233) for cooperative drain.
    supervisor = E2E::DaemonSupervisor.new(wallet_names: names, network: :mainnet)
    supervisor.start_all
    BSV::Wallet.emit('e2e.daemons.up', count: supervisor.log_paths.size)

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

        # Termination — both conditions must hold per HLR.
        if accepted >= min_tx && (current_height - starting_height) >= min_blocks
          BSV::Wallet.emit('e2e.broadcast.termination',
                           reason: 'min_tx_and_min_blocks_met',
                           accepted: accepted, blocks_mined: current_height - starting_height)
          break
        end

        wait_s = next_cycle_at - monotonic_now
        sleep wait_s if wait_s.positive?
      end
    ensure
      drain_results = supervisor.stop_all
      BSV::Wallet.emit('e2e.daemons.down',
                       drained: drain_results.values.count(:drained),
                       killed: drain_results.values.count(:killed))
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
    expect(blocks_mined).to be >= min_blocks,
                            "only #{blocks_mined} blocks mined (expected >= #{min_blocks})"
  end
end
