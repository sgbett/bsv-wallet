# frozen_string_literal: true

# Phase 3 of the #126 e2e on-chain harness — the actual broadcasting.
#
# Drives ~10_000 on-chain transactions over ~1 hour to surface:
#   - Stale-BEEF behaviour (rate, outcome) — logged, not remediated.
#     The daemon's proof-acquisition loop refreshes proofs in the
#     background; rejects are recorded but the broadcast retries
#     naturally on the next cycle.
#   - Block-boundary continuity — does the wallet's view stay coherent
#     across ≥3 mined blocks?
#   - Sustained throughput against multi-provider ARC routing.
#
# Pattern (per HLR + strategy doc §Broadcast Timing):
#   400 cycles × 25 tx every 9s (absolute interval) = ~10k tx, ~1hr.
#   Sender + recipient chosen at random (not-self). Amount drawn from
#   clamp(round(Normal(mean=5000, sd=1000)), 1000, 9000) — bounded
#   away from dust + above the per-input marginal fee.
#   accept_delayed_broadcast: false, no_send: false — inline ARC submit.
#
# Termination: at least +BROADCAST_MIN_TX+ accepted broadcasts AND
# at least +BROADCAST_MIN_BLOCKS+ blocks mined since the test started.
# Both must hold simultaneously.
#
# Daemons: one +walletd+ subprocess per wallet runs in the background
# for the duration. Their proof-acquisition loop keeps the proof_store
# current so subsequent BEEFs build on confirmed ancestors.
#
# Restart: this phase is NOT safe to resume mid-run. The cleanup
# phase (run standalone) restores wallets to a state where a fresh
# Phase 1 can begin.
#
# Tunables for dev iteration:
#   BROADCAST_CYCLES        (default 400)
#   BROADCAST_PER_CYCLE     (default 25)
#   BROADCAST_INTERVAL_S    (default 9)
#   BROADCAST_MIN_TX        (default 10_000)
#   BROADCAST_MIN_BLOCKS    (default 3)
#   BROADCAST_AMOUNT_MEAN   (default 5000)
#   BROADCAST_AMOUNT_SD     (default 1000)
#   BROADCAST_AMOUNT_MIN    (default 1000)
#   BROADCAST_AMOUNT_MAX    (default 9000)

require_relative 'spec_helper'

RSpec.describe 'e2e Phase 3 — broadcast loop' do # rubocop:disable RSpec/DescribeClass
  let(:cycles)        { (ENV['BROADCAST_CYCLES']     || 400).to_i }
  let(:per_cycle)     { (ENV['BROADCAST_PER_CYCLE']  || 25).to_i }
  let(:interval_s)    { (ENV['BROADCAST_INTERVAL_S'] || 9).to_i }
  let(:min_tx)        { (ENV['BROADCAST_MIN_TX']     || 10_000).to_i }
  let(:min_blocks)    { (ENV['BROADCAST_MIN_BLOCKS'] || 3).to_i }
  let(:amount_mean)   { (ENV['BROADCAST_AMOUNT_MEAN'] || 5000).to_i }
  let(:amount_sd)     { (ENV['BROADCAST_AMOUNT_SD']   || 1000).to_i }
  let(:amount_min)    { (ENV['BROADCAST_AMOUNT_MIN']  || 1000).to_i }
  let(:amount_max)    { (ENV['BROADCAST_AMOUNT_MAX']  || 9000).to_i }
  let(:received_basket) { 'received' }

  before do
    missing = E2E::WalletHarness.missing_env
    skip "Phase 3 requires env: #{missing.join(', ')}" unless missing.empty?
    E2E::EventLog.start
  end

  after { E2E::EventLog.stop }

  # Clamped normal-distribution amount per HLR §Broadcast Timing.
  def random_amount
    # Box-Muller — cheap, no dependency. Two uniforms → one normal.
    u1 = rand
    u2 = rand
    z = Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math::PI * u2)
    raw = (amount_mean + (z * amount_sd)).round
    raw.clamp(amount_min, amount_max)
  end

  def internalize_at(recipient_ctx, payment, description:)
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

  # Drive one inline-broadcast payment. Returns +:accepted+ on success,
  # +:failed+ on any exception (logged with the exception class +
  # message head — categorisation by post-processing the log).
  def drive_one_payment(ctxs, names)
    sender = names.sample
    recipient = (names - [sender]).sample
    amount = random_amount
    sender_ctx = ctxs[sender]
    recipient_ctx = ctxs[recipient]

    begin
      payment = sender_ctx[:engine].send_payment(
        recipient: recipient_ctx[:key_deriver].identity_key,
        satoshis: amount,
        no_send: false, accept_delayed_broadcast: false
      )
      internalize_at(recipient_ctx, payment, description: 'phase 3 broadcast')
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

  it 'sustains ~25 tx/9s for ~10k tx across ≥3 blocks' do
    # Boot in-process engines for the five test wallets.
    E2E::WalletHarness.install_derived_wifs!
    test_ctxs = E2E::WalletHarness.test_wallet_names.to_h do |name|
      [name, E2E::WalletHarness.boot(name)]
    end

    # Spawn a walletd subprocess per wallet so proof-acquisition runs
    # in the background while the harness pushes broadcasts. The
    # supervisor's stop_all relies on Scheduler#shutdown (#233) for
    # cooperative drain.
    supervisor = E2E::DaemonSupervisor.new(
      wallet_names: E2E::WalletHarness.test_wallet_names,
      network: :mainnet
    )
    supervisor.start_all
    BSV::Wallet.emit('e2e.phase3.daemons.up', count: supervisor.log_paths.size)

    # Use any wallet's Engine#services for the chain-height query —
    # affinity is irrelevant for +current_height+ (no per-tx caching),
    # and reusing the wallet's stack inherits the same provider order
    # as the broadcast path.
    chain_services = test_ctxs.values.first[:engine].services
    starting_height = current_block_height(chain_services)
    BSV::Wallet.emit('e2e.phase3.start',
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
          outcome = drive_one_payment(test_ctxs, E2E::WalletHarness.test_wallet_names)
          if outcome == :accepted
            accepted += 1
          else
            failed += 1
          end
        end

        current_height = current_block_height(chain_services)
        cycle_completed = cycle_idx + 1
        BSV::Wallet.emit('e2e.phase3.cycle',
                         n: cycle_completed, accepted: accepted, failed: failed,
                         height: current_height,
                         blocks_mined: current_height - starting_height)

        # Termination — both conditions must hold per HLR.
        if accepted >= min_tx && (current_height - starting_height) >= min_blocks
          BSV::Wallet.emit('e2e.phase3.termination',
                           reason: 'min_tx_and_min_blocks_met',
                           accepted: accepted, blocks_mined: current_height - starting_height)
          break
        end

        wait_s = next_cycle_at - monotonic_now
        sleep wait_s if wait_s.positive?
      end
    ensure
      drain_results = supervisor.stop_all
      BSV::Wallet.emit('e2e.phase3.daemons.down',
                       drained: drain_results.values.count(:drained),
                       killed: drain_results.values.count(:killed))
    end

    blocks_mined = current_height - starting_height
    warn "\n=== Phase 3 broadcast summary ==="
    warn "  cycles completed: #{cycle_completed} / #{cycles}"
    warn "  accepted: #{accepted}  failed: #{failed}"
    warn "  blocks: #{starting_height} → #{current_height} (Δ #{blocks_mined})"
    warn "===\n"
    BSV::Wallet.emit('e2e.phase3.complete',
                     accepted: accepted, failed: failed,
                     blocks_mined: blocks_mined,
                     cycles_completed: cycle_completed)

    expect(accepted).to be >= min_tx,
                        "only #{accepted} accepted broadcasts (expected >= #{min_tx})"
    expect(blocks_mined).to be >= min_blocks,
                            "only #{blocks_mined} blocks mined (expected >= #{min_blocks})"
  end
end
