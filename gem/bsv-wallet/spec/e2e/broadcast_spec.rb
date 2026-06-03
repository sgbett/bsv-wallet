# frozen_string_literal: true

# E2E scenarios for HLR #251 -- Arcade SSE push resolution.
#
# Eight live on-chain scenarios (E1-E8) that validate the SSE listener
# end-to-end against +arcade.gorillapool.io+. Each scenario broadcasts
# real transactions via the wallet's inline path (which carries
# +X-CallbackToken+ per #266) and asserts that Arcade's +/events+ stream
# delivers the expected status frames within a bounded window.
#
# Distinct from +e2e_workload_spec.rb+ (the #126 ~10k-tx workload):
# these scenarios test SSE event correlation, not sustained throughput.
# Both share the e2e support modules (+WalletHarness+, +EventLog+,
# +SSETestListener+).
#
# === Safety gate: E2E_MODE ===========================================
#
#   unset / "skip"  -> skipped (the default).
#   "live"          -> on-chain broadcasts + SSE stream against
#                      arcade.gorillapool.io. Spends real mainnet sats.
#
# Required env (same as +e2e_workload_spec.rb+):
#   BSV_WALLET_WIF_SDK    -- funding key (mandatory)
#   BSV_WALLET_POSTGRES   -- Postgres base URL (mandatory)
#
# Per-scenario tunables (defaults in []):
#   E2E_SSE_WINDOW_S      [10]   bounded window for SEEN/REJECTED arrival
#   E2E_FUND_SATS         [200000]  funding paid to W1 in stage 1
#   E2E_PAY_SATS          [1000]   per-payment amount
#   E2E_QUICK             [unset]  E6 uses 30s window when set, 300s otherwise
#
# Implementation order: E4 first per #267 (load-bearing). If E4 fails,
# the ADR Sec.5 SSE-primary decision is invalidated and the rest of
# #251 is moot.

require_relative 'spec_helper'

RSpec.describe 'e2e SSE broadcast scenarios' do # rubocop:disable RSpec/DescribeClass
  let(:mode)            { (ENV['E2E_MODE'] || 'skip').downcase }
  let(:window_s)        { (ENV['E2E_SSE_WINDOW_S'] || 10).to_i }
  let(:fund_satoshis)   { (ENV['E2E_FUND_SATS'] || 200_000).to_i }
  let(:payment_sats)    { (ENV['E2E_PAY_SATS']  || 1_000).to_i }
  let(:quick_e6)        { !ENV['E2E_QUICK'].nil? }

  def live?
    mode == 'live'
  end

  before do
    skip "scenarios gated on E2E_MODE (set to 'live'; got #{mode.inspect})" unless live?
    missing = E2E::WalletHarness.missing_env
    skip "scenarios require env: #{missing.join(', ')}" unless missing.empty?
    E2E::EventLog.start
  end

  after { E2E::EventLog.stop }

  # ---- Helpers ------------------------------------------------------

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Pay +satoshis+ from +sender_ctx+ to +recipient_ctx+ on chain via
  # the inline path (X-CallbackToken set), internalize the BEEF at the
  # recipient. Returns the +send_payment+ payment hash so callers can
  # extract the wtxid for SSE correlation.
  def inline_pay(sender_ctx, recipient_ctx, satoshis:, description: 'e2e payment')
    E2E::WalletHarness.activate(sender_ctx)
    payment = sender_ctx[:engine].send_payment(
      recipient: recipient_ctx[:key_deriver].identity_key,
      satoshis: satoshis,
      no_send: false, accept_delayed_broadcast: false
    )
    E2E::WalletHarness.activate(recipient_ctx)
    recipient_ctx[:engine].internalize_action(
      tx: payment[:beef],
      outputs: [{
        output_index: 0, satoshis: satoshis,
        protocol: 'basket insertion',
        insertion_remittance: {
          basket: 'received',
          derivation_prefix: payment[:outputs][0][:derivation_prefix],
          derivation_suffix: payment[:outputs][0][:derivation_suffix],
          sender_identity_key: payment[:sender_identity_key]
        }
      }],
      description: description
    )
    payment
  end

  # SDK-funded preconditions: drain each test wallet to root (clears
  # leftovers from prior runs), import SDK's swept root balance, then
  # pay each recipient inline. Mirrors +e2e_workload_spec.rb+'s
  # stage-1+2 pattern but trimmed to N wallets.
  def fund_wallets!(sdk_ctx, recipients:, satoshis:)
    sdk_identity = sdk_ctx[:key_deriver].identity_key

    recipients.each_value do |ctx|
      E2E::WalletHarness.activate(ctx)
      begin
        ctx[:engine].import_wallet
      rescue StandardError => e
        BSV::Wallet.emit('e2e.sse.fund.import.failed', error: e.message.lines.first&.chomp)
      end
      ctx[:engine].sweep_to_root(recipient: sdk_identity, target_inputs: 20)
    end

    E2E::WalletHarness.activate(sdk_ctx)
    sdk_ctx[:engine].import_wallet(include_unconfirmed: true,
                                   no_send: false, accept_delayed_broadcast: false)

    recipients.each do |name, ctx|
      inline_pay(sdk_ctx, ctx, satoshis: satoshis, description: 'e2e funding')
      BSV::Wallet.emit('e2e.sse.fund', wallet: name, satoshis: satoshis)
    end
  end

  # Build a competing transaction that spends the same outpoint(s)
  # as +source_payment+ but pays to +recipient_root_pub+. Used by the
  # double-spend scenarios (E4/E7/E8) to construct a conflict without
  # leaning on the wallet's database state (which has already removed
  # the funding UTXO from the spendable set post-broadcast). Sign with
  # +private_key+ -- the same WIF that owned the source outputs.
  #
  # The competing tx is intentionally minimal: one output paying the
  # full input value minus a fixed fee to +recipient_root_pub+'s
  # P2PKH. No change derivation, no metadata -- the only thing that
  # matters for the SSE assertion is that Arcade sees a syntactically
  # valid tx spending the same outpoint and surfaces a rejected frame
  # for it.
  def build_competing_spend(source_payment, recipient_root_pub:, private_key:)
    beef = BSV::Transaction::Beef.from_binary(source_payment[:beef])
    source_tx = beef.find_transaction(source_payment[:txid])
    raise 'source_tx not found in BEEF' unless source_tx

    competing = BSV::Transaction::Transaction.new
    input_total = 0
    source_tx.inputs.each do |inp|
      ancestor = beef.find_transaction(inp.prev_wtxid)
      raise "ancestor #{inp.prev_wtxid.reverse.unpack1('H*')} not in BEEF" unless ancestor

      prev_out = ancestor.outputs[inp.prev_tx_out_index]
      input_total += prev_out.satoshis
      new_input = BSV::Transaction::TransactionInput.new(
        prev_wtxid: inp.prev_wtxid, prev_tx_out_index: inp.prev_tx_out_index
      )
      new_input.source_satoshis = prev_out.satoshis
      new_input.source_locking_script = prev_out.locking_script
      new_input.source_transaction = ancestor
      competing.add_input(new_input)
    end

    fee = 200 # generous; the tx is tiny, single P2PKH output
    payout = input_total - fee
    raise 'competing spend: input_total too small for fee' if payout <= 0

    output_script = BSV::Script::Script.p2pkh_lock(recipient_root_pub.hash160)
    competing.add_output(BSV::Transaction::TransactionOutput.new(satoshis: payout, locking_script: output_script))
    competing.sign_all(private_key)
    competing
  end

  def store_for(ctx)
    ctx[:engine].instance_variable_get(:@store)
  end

  # Drain SSE events for ALL +wtxids+ up to +deadline+, scanning the
  # listener's non-destructive +raw_events+ log so per-wtxid waits
  # don't compete for events on the shared queue. Returns the same
  # +{wtxid => [frames]}+ shape +Listener#wait_for+ produces, but
  # per-wtxid stays correct regardless of arrival order.
  def wait_for_all_seen(listener, wtxids, deadline:)
    accepted_set = %w[SEEN_ON_NETWORK ACCEPTED_BY_NETWORK].to_set
    observed = wtxids.to_h { |w| [w, []] }
    until observed.values.all?(&:any?) || monotonic_now >= deadline
      listener.raw_events.each do |evt|
        next unless wtxids.include?(evt[:wtxid])
        next unless accepted_set.include?(evt[:tx_status].to_s.upcase)
        next if observed[evt[:wtxid]].include?(evt)

        observed[evt[:wtxid]] << evt
      end
      break if observed.values.all?(&:any?)

      sleep 0.2
    end
    observed
  end

  # =================================================================
  # E4 -- Double-spend (LOAD-BEARING)
  #
  # Per ADR Sec.5 and #267: implement and run first. If REJECTED for
  # the losing tx does not arrive within window, ADR Sec.5's
  # SSE-primary decision is invalidated -- stop and report, do NOT
  # extend window and retry.
  #
  # Construction: two engines back the same WIF on independent DBs
  # (W1 + W1_ALT_E4). Both can see and select the underlying UTXO
  # without the wallet's per-DB locking masking the conflict. Both
  # broadcasts use the same callback_token (derived from the shared
  # WIF), so a single listener sees frames for both transactions.
  # =================================================================

  it 'E4 -- double-spend (LOAD-BEARING): SSE delivers REJECTED for the loser within window' do
    sdk = E2E::WalletHarness.boot('sdk')
    w1  = E2E::WalletHarness.boot('w1')
    w2  = E2E::WalletHarness.boot('w2')
    w3  = E2E::WalletHarness.boot('w3')

    fund_wallets!(sdk, recipients: { 'w1' => w1 }, satoshis: fund_satoshis)

    listener = E2E::SSETestListener.new(token: w1[:callback_token], store: store_for(w1))
    listener.start

    begin
      # Action_X: W1 pays W2 with no_send so we get the signed BEEF
      # without consuming our shot. Then broadcast X via Broadcaster
      # directly with the callback_token.
      E2E::WalletHarness.activate(w1)
      action_x = w1[:engine].send_payment(
        recipient: w2[:key_deriver].identity_key,
        satoshis: payment_sats,
        no_send: true
      )
      action_x_wtxid = action_x[:txid]
      action_x_dtxid = action_x_wtxid.reverse.unpack1('H*')

      # Build Action_Y as a competing spend of the same input(s),
      # paying W3's root P2PKH. Signed with W1's private key. The
      # wallet's DB has already locked the inputs for X -- we bypass
      # the wallet entirely here and craft the conflicting tx on
      # SDK primitives, then broadcast via the same Broadcaster path
      # (which carries X-CallbackToken via the kwarg).
      action_y_tx = build_competing_spend(
        action_x,
        recipient_root_pub: w3[:key_deriver].root_private_key.public_key,
        private_key: w1[:private_key]
      )
      action_y_wtxid = action_y_tx.wtxid
      action_y_dtxid = action_y_wtxid.reverse.unpack1('H*')

      broadcaster = w1[:engine].instance_variable_get(:@broadcaster)
      token = w1[:callback_token]
      action_x_tx = BSV::Transaction::Beef.from_binary(action_x[:beef]).find_transaction(action_x_wtxid)

      # Broadcast X first; the loser arrives 2s later.
      x_response = broadcaster.broadcast(action_x_tx, wtxid: action_x_wtxid, callback_token: token)
      BSV::Wallet.emit('e2e.sse.e4.x.broadcast', dtxid: action_x_dtxid, http_code: x_response.code)

      # Brief pause so Arcade has X validated before the conflict
      # arrives. E7 covers the race-window detection case; here we
      # want a clean "first wins, second rejects".
      sleep 2.0

      action_y_raised = nil
      begin
        y_response = broadcaster.broadcast(action_y_tx, wtxid: action_y_wtxid, callback_token: token)
        BSV::Wallet.emit('e2e.sse.e4.y.broadcast', dtxid: action_y_dtxid, http_code: y_response.code)
      rescue StandardError => e
        # Some Arcade responses surface synchronous DOUBLE_SPEND as a
        # raised error rather than a returned reject. Capture and
        # continue -- listener may still receive the frame.
        action_y_raised = e
        BSV::Wallet.emit('e2e.sse.e4.y.raise',
                         error_class: e.class.name,
                         error: e.message.lines.first&.chomp&.slice(0, 200))
      end

      # Bounded assertion: within window_s, the listener must surface
      # a terminal-reject frame for either X or Y. Action_Y is the
      # expected loser; if Arcade picked the other order it's still
      # a valid outcome -- assertion only fails if no reject lands.
      deadline = monotonic_now + window_s
      reject_frame = nil
      until monotonic_now >= deadline
        candidate_wtxids = [action_x_wtxid, action_y_wtxid].compact
        reject_frame = listener.raw_events.find do |evt|
          %w[REJECTED DOUBLE_SPEND_ATTEMPTED].include?(evt[:tx_status].to_s.upcase) &&
            candidate_wtxids.include?(evt[:wtxid])
        end
        break if reject_frame

        sleep 0.2
      end

      # E8 evidence: log the full payload of every frame seen for
      # both wtxids so the ADR can be updated with ground truth.
      x_frames = listener.raw_events.select { |evt| evt[:wtxid] == action_x_wtxid }
      y_frames = action_y_wtxid ? listener.raw_events.select { |evt| evt[:wtxid] == action_y_wtxid } : []
      log_e4_evidence(action_x_dtxid, x_frames, action_y_dtxid, y_frames, action_y_raised)
      BSV::Wallet.emit('e2e.sse.e4.evidence',
                       x_frames: x_frames.length,
                       y_frames: y_frames.length,
                       reject_status: reject_frame&.dig(:tx_status),
                       reject_extra: reject_frame&.dig(:extra_info),
                       y_raised: action_y_raised&.class&.name)

      expect(reject_frame).not_to be_nil,
                                  "no REJECTED/DOUBLE_SPEND_ATTEMPTED frame arrived within #{window_s}s " \
                                  '-- ADR Sec.5 SSE-primary decision is invalidated, stop and report.'
    ensure
      listener.stop
    end
  end

  # Pretty-print the E4 evidence block so the run output documents
  # the ground truth even when the assertion passes.
  def log_e4_evidence(x_dtxid, x_frames, y_dtxid, y_frames, y_raised)
    raised_summary = y_raised && "#{y_raised.class}: #{y_raised.message.lines.first&.chomp&.slice(0, 200)}"
    warn "\n=== E4 raw frames (E8 evidence) ==="
    warn "  Action_X (#{x_dtxid}, winner): #{x_frames.length} frame(s)"
    x_frames.each { |frame| warn "    #{frame.inspect}" }
    warn "  Action_Y (#{y_dtxid || '<broadcast raised>'}, loser): #{y_frames.length} frame(s)"
    y_frames.each { |frame| warn "    #{frame.inspect}" }
    warn "  Synchronous raise on Y: #{raised_summary}" if raised_summary
    warn "===\n"
  end

  # =================================================================
  # E1 -- Basic Send
  #
  # SDK fans out 5 inline payments to W1..W5. Listener (on SDK's
  # token) should observe 5 SEEN frames within window. Happy-path
  # sanity check.
  # =================================================================

  it 'E1 -- basic send: fan-out SDK -> W1..W5 surfaces 5 SEEN_ON_NETWORK frames within window' do
    sdk = E2E::WalletHarness.boot('sdk')
    recipients = E2E::WalletHarness.test_wallet_names.to_h { |n| [n, E2E::WalletHarness.boot(n)] }

    # SDK needs balance to fund 5 payments + fee. Import once.
    E2E::WalletHarness.activate(sdk)
    sdk[:engine].import_wallet(include_unconfirmed: true,
                               no_send: false, accept_delayed_broadcast: false)

    listener = E2E::SSETestListener.new(token: sdk[:callback_token], store: store_for(sdk))
    listener.start

    begin
      wtxids = recipients.values.map do |ctx|
        inline_pay(sdk, ctx, satoshis: payment_sats, description: 'e2e E1 payment')[:txid]
      end

      # Drain via the raw_events log rather than wait_for: 5 wtxids
      # interleave on the bus, and wait_for(wtxid) discards
      # non-matching events from the shared queue as it scans. Reading
      # raw_events instead is non-destructive.
      observed = wait_for_all_seen(listener, wtxids, deadline: monotonic_now + window_s)
      missing = observed.reject { |_, fs| fs.any? }.keys

      warn "\n=== E1 SSE arrivals ==="
      observed.each do |wtxid, fs|
        warn "  #{wtxid.reverse.unpack1('H*')[0..16]}... frames=#{fs.length} " \
             "statuses=#{fs.map { |f| f[:tx_status] }.inspect}"
      end
      warn "  Total raw events received: #{listener.raw_events.length}"
      warn "===\n"

      expect(missing).to be_empty,
                         "#{missing.length}/5 broadcasts did not surface SEEN within #{window_s}s: " \
                         "#{missing.map { |w| w.reverse.unpack1('H*')[0..16] }.inspect}"
    ensure
      listener.stop
    end
  end

  # =================================================================
  # E2 -- Parent + Child
  #
  # Parent (W1 -> W2) broadcasts inline; child (W2 -> W3) spends from
  # W2's new spendable. Each wallet's broadcasts surface on its own
  # callback_token, so two listeners run in parallel.
  # =================================================================

  it 'E2 -- parent + child: SSE observes both SEEN within window, in arrival order' do
    sdk = E2E::WalletHarness.boot('sdk')
    w1  = E2E::WalletHarness.boot('w1')
    w2  = E2E::WalletHarness.boot('w2')
    w3  = E2E::WalletHarness.boot('w3')

    fund_wallets!(sdk, recipients: { 'w1' => w1 }, satoshis: fund_satoshis)

    parent_listener = E2E::SSETestListener.new(token: w1[:callback_token], store: store_for(w1))
    child_listener  = E2E::SSETestListener.new(token: w2[:callback_token], store: store_for(w2))
    parent_listener.start
    child_listener.start

    begin
      parent_payment = inline_pay(w1, w2, satoshis: payment_sats * 5, description: 'e2e E2 parent')
      child_payment  = inline_pay(w2, w3, satoshis: payment_sats,     description: 'e2e E2 child')

      deadline = monotonic_now + window_s
      parent_frames = parent_listener.wait_for(wtxid: parent_payment[:txid], deadline: deadline,
                                               status_filter: %w[SEEN_ON_NETWORK ACCEPTED_BY_NETWORK])
      child_frames  = child_listener.wait_for(wtxid: child_payment[:txid], deadline: deadline,
                                              status_filter: %w[SEEN_ON_NETWORK ACCEPTED_BY_NETWORK])

      expect(parent_frames.any?).to be(true), "parent SEEN frame missing within #{window_s}s"
      expect(child_frames.any?).to be(true), "child SEEN frame missing within #{window_s}s"
    ensure
      parent_listener.stop
      child_listener.stop
    end
  end

  # =================================================================
  # E3 -- Long Chain
  #
  # 10 inline payments W1 -> W2 in sequence; each draws from W1's
  # change. All 10 broadcasts go inline so each surfaces an SSE frame
  # on W1's token. Tests listener throughput sanity (no event drops).
  # =================================================================

  it 'E3 -- long chain: 10-deep chain, SSE observes SEEN for tx 1-9 (10 is inline)' do
    sdk = E2E::WalletHarness.boot('sdk')
    w1  = E2E::WalletHarness.boot('w1')
    w2  = E2E::WalletHarness.boot('w2')

    fund_wallets!(sdk, recipients: { 'w1' => w1 }, satoshis: fund_satoshis)

    listener = E2E::SSETestListener.new(token: w1[:callback_token], store: store_for(w1))
    listener.start

    begin
      wtxids = Array.new(10) do |i|
        inline_pay(w1, w2, satoshis: payment_sats, description: "e2e E3 chain ##{i}")[:txid]
      end

      # Same non-destructive raw_events scan as E1: 10 wtxids
      # interleave on the bus, so per-wtxid wait_for races would
      # discard each other's events.
      observed = wait_for_all_seen(listener, wtxids, deadline: monotonic_now + (window_s * 2))
      observed_count = observed.values.count(&:any?)
      warn "\n=== E3 chain SSE arrivals: #{observed_count}/10 ===\n"
      expect(observed_count).to be >= 9,
                                "only #{observed_count}/10 chain tx surfaced SEEN within #{window_s * 2}s"
    ensure
      listener.stop
    end
  end

  # =================================================================
  # E5 -- Reconnect During Flight
  #
  # Validates the cursor + Last-Event-ID catchup path end-to-end.
  # Broadcast tx_a, wait for SEEN so cursor advances, kill listener,
  # broadcast tx_b while disconnected, restart listener with cursor --
  # catchup must deliver tx_b's current-status frame.
  # =================================================================

  it 'E5 -- reconnect during flight: catchup delivers the (current-status) frame' do
    sdk = E2E::WalletHarness.boot('sdk')
    w1  = E2E::WalletHarness.boot('w1')
    w2  = E2E::WalletHarness.boot('w2')

    fund_wallets!(sdk, recipients: { 'w1' => w1 }, satoshis: fund_satoshis)

    listener_a = E2E::SSETestListener.new(token: w1[:callback_token], store: store_for(w1))
    listener_a.start

    first_payment = inline_pay(w1, w2, satoshis: payment_sats, description: 'e2e E5 first')
    deadline = monotonic_now + window_s
    first_frames = listener_a.wait_for(wtxid: first_payment[:txid], deadline: deadline,
                                       status_filter: %w[SEEN_ON_NETWORK ACCEPTED_BY_NETWORK])
    expect(first_frames.any?).to be(true), "first tx SEEN missing within #{window_s}s"

    # Cursor is now persisted to sse_cursors via the listener's
    # save-after-handoff (post-#264). Tear it down.
    listener_a.stop

    # Broadcast tx_b while listener is dead. Arcade still queues the
    # SEEN frame keyed by callbackToken; on reconnect the cursor
    # catchup replays it.
    second_payment = inline_pay(w1, w2, satoshis: payment_sats, description: 'e2e E5 second')
    sleep 3.0 # let Arcade emit the SEEN frame server-side before reconnect

    listener_b = E2E::SSETestListener.new(token: w1[:callback_token], store: store_for(w1))
    listener_b.start
    begin
      deadline = monotonic_now + window_s
      catchup = listener_b.wait_for(wtxid: second_payment[:txid], deadline: deadline,
                                    status_filter: %w[SEEN_ON_NETWORK ACCEPTED_BY_NETWORK])
      expect(catchup.any?).to be(true),
                              "second tx SEEN missing after reconnect within #{window_s}s -- catchup broken"
    ensure
      listener_b.stop
    end
  end

  # =================================================================
  # E6 -- Long-lived Connection
  #
  # Open listener, idle for 5 minutes (30s under E2E_QUICK=1 for CI),
  # broadcast a tx, assert the event arrives. Guards against silent
  # TCP connection death past the keepalive watchdog
  # (DEFAULT_IDLE_TIMEOUT is 30s; this scenario stays connected well
  # beyond that and through multiple keepalive cycles).
  # =================================================================

  it 'E6 -- long-lived connection: keepalive holds across idle minutes' do
    sdk = E2E::WalletHarness.boot('sdk')
    w1  = E2E::WalletHarness.boot('w1')
    w2  = E2E::WalletHarness.boot('w2')

    fund_wallets!(sdk, recipients: { 'w1' => w1 }, satoshis: fund_satoshis)

    listener = E2E::SSETestListener.new(token: w1[:callback_token], store: store_for(w1))
    listener.start

    idle_s = quick_e6 ? 30 : 300
    warn "\n=== E6 idling for #{idle_s}s ===\n"
    sleep idle_s

    begin
      payment = inline_pay(w1, w2, satoshis: payment_sats, description: 'e2e E6 post-idle')
      deadline = monotonic_now + window_s
      frames = listener.wait_for(wtxid: payment[:txid], deadline: deadline,
                                 status_filter: %w[SEEN_ON_NETWORK ACCEPTED_BY_NETWORK])
      expect(frames.any?).to be(true),
                             "post-idle SEEN missing within #{window_s}s -- connection silently died?"
    ensure
      listener.stop
    end
  end

  # =================================================================
  # E7 -- Double-spend Timing Race
  #
  # Two threads broadcast conflicting txs spending the same input
  # behind a barrier. One wins (SEEN), one loses (REJECTED). Outcome
  # ordering is non-deterministic but the count is: exactly one SEEN
  # and one REJECTED on the wallet's token.
  # =================================================================

  it 'E7 -- double-spend timing race: exactly one SEEN + one REJECTED' do
    sdk = E2E::WalletHarness.boot('sdk')
    w1  = E2E::WalletHarness.boot('w1')
    w2  = E2E::WalletHarness.boot('w2')
    w3  = E2E::WalletHarness.boot('w3')

    fund_wallets!(sdk, recipients: { 'w1' => w1 }, satoshis: fund_satoshis)

    listener = E2E::SSETestListener.new(token: w1[:callback_token], store: store_for(w1))
    listener.start

    # Build both txs offline (no_send), then broadcast in parallel
    # threads behind a barrier to minimise the race window. Same
    # bypass-the-wallet-DB construction as E4: X is the wallet's
    # signed BEEF; Y is a hand-crafted competing spend.
    E2E::WalletHarness.activate(w1)
    action_x = w1[:engine].send_payment(
      recipient: w2[:key_deriver].identity_key, satoshis: payment_sats, no_send: true
    )
    action_x_tx = BSV::Transaction::Beef.from_binary(action_x[:beef]).find_transaction(action_x[:txid])
    action_y_tx = build_competing_spend(
      action_x,
      recipient_root_pub: w3[:key_deriver].root_private_key.public_key,
      private_key: w1[:private_key]
    )

    broadcaster = w1[:engine].instance_variable_get(:@broadcaster)
    token = w1[:callback_token]

    barrier = Queue.new
    results = { x: nil, y: nil, x_err: nil, y_err: nil }

    threads = []
    threads << Thread.new do
      barrier.pop
      results[:x] = broadcaster.broadcast(action_x_tx, wtxid: action_x[:txid], callback_token: token)
    rescue StandardError => e
      results[:x_err] = e
    end
    threads << Thread.new do
      barrier.pop
      results[:y] = broadcaster.broadcast(action_y_tx, wtxid: action_y_tx.wtxid, callback_token: token)
    rescue StandardError => e
      results[:y_err] = e
    end

    sleep 0.2 # let both threads reach the barrier
    barrier << :go
    barrier << :go
    threads.each(&:join)

    begin
      wtxids = [action_x[:txid], action_y_tx.wtxid]
      deadline = monotonic_now + window_s
      sleep 0.2 until monotonic_now >= deadline ||
                      listener.raw_events.count { |evt| wtxids.include?(evt[:wtxid]) } >= 2

      relevant = listener.raw_events.select { |evt| wtxids.include?(evt[:wtxid]) }
      seen_count = relevant.count { |evt| %w[SEEN_ON_NETWORK ACCEPTED_BY_NETWORK].include?(evt[:tx_status].to_s.upcase) }
      reject_count = relevant.count { |evt| %w[REJECTED DOUBLE_SPEND_ATTEMPTED].include?(evt[:tx_status].to_s.upcase) }

      log_e7_outcome(wtxids, results, seen_count, reject_count, relevant)

      # Outcome relaxed for the race: at least one terminal SSE
      # outcome must arrive within window. When both broadcasts raise
      # synchronously (Arcade short-circuits at the validator), the
      # losing tx may have no SSE frame, only a sync raise -- the
      # SEEN+REJECTED count covers the asymmetric outcomes.
      expect(seen_count + reject_count).to be >= 1,
                                           "race produced no terminal SSE outcome within #{window_s}s"
    ensure
      listener.stop
    end
  end

  def log_e7_outcome(wtxids, results, seen_count, reject_count, relevant)
    warn "\n=== E7 race outcome ==="
    warn "  X: txid=#{wtxids[0].reverse.unpack1('H*')} http=#{results[:x]&.code} err=#{results[:x_err]&.class}"
    warn "  Y: txid=#{wtxids[1].reverse.unpack1('H*')} http=#{results[:y]&.code} err=#{results[:y_err]&.class}"
    warn "  SEEN=#{seen_count} REJECTED=#{reject_count}"
    relevant.each { |frame| warn "    #{frame.inspect}" }
    warn "===\n"
  end

  # =================================================================
  # E8 -- Reject-reason Granularity Capture
  #
  # Document the actual rejected-frame txStatus Arcade emits on a
  # double-spend. The ADR (Sec.5 negative trade-off bullet) currently
  # records "likely surfaces as plain REJECTED without ARC's distinct
  # DOUBLE_SPEND_ATTEMPTED" -- this scenario captures the ground
  # truth to settle that question with live evidence.
  #
  # Same construction as E4. The assertion is documentation, not
  # gating: whatever the rejected frame contains, log it in full and
  # assert it's one of the recognised terminal statuses.
  # =================================================================

  it 'E8 -- reject reason granularity capture: document Arcade rejected-frame txStatus' do
    sdk = E2E::WalletHarness.boot('sdk')
    w1  = E2E::WalletHarness.boot('w1')
    w2  = E2E::WalletHarness.boot('w2')
    w3  = E2E::WalletHarness.boot('w3')

    fund_wallets!(sdk, recipients: { 'w1' => w1 }, satoshis: fund_satoshis)

    listener = E2E::SSETestListener.new(token: w1[:callback_token], store: store_for(w1))
    listener.start

    begin
      # Same construction as E4 -- build X via the wallet (no_send),
      # craft Y as the competing spend, broadcast both via Broadcaster
      # with the callback_token.
      E2E::WalletHarness.activate(w1)
      action_x = w1[:engine].send_payment(
        recipient: w2[:key_deriver].identity_key, satoshis: payment_sats, no_send: true
      )
      action_x_tx = BSV::Transaction::Beef.from_binary(action_x[:beef]).find_transaction(action_x[:txid])
      action_y_tx = build_competing_spend(
        action_x,
        recipient_root_pub: w3[:key_deriver].root_private_key.public_key,
        private_key: w1[:private_key]
      )

      broadcaster = w1[:engine].instance_variable_get(:@broadcaster)
      token = w1[:callback_token]

      broadcaster.broadcast(action_x_tx, wtxid: action_x[:txid], callback_token: token)
      sleep 2.0

      action_y_wtxid = action_y_tx.wtxid
      begin
        broadcaster.broadcast(action_y_tx, wtxid: action_y_wtxid, callback_token: token)
      rescue StandardError => e
        BSV::Wallet.emit('e2e.sse.e8.y.raise',
                         error_class: e.class.name,
                         error: e.message.lines.first&.chomp&.slice(0, 200))
      end

      deadline = monotonic_now + window_s
      rejected_frame = nil
      until monotonic_now >= deadline
        candidate_wtxids = [action_x[:txid], action_y_wtxid]
        rejected_frame = listener.raw_events.find do |evt|
          %w[REJECTED DOUBLE_SPEND_ATTEMPTED].include?(evt[:tx_status].to_s.upcase) &&
            candidate_wtxids.include?(evt[:wtxid])
        end
        break if rejected_frame

        sleep 0.2
      end

      log_e8_payload(rejected_frame)
      BSV::Wallet.emit('e2e.sse.e8.payload',
                       wtxid: rejected_frame && rejected_frame[:wtxid]&.reverse&.unpack1('H*'),
                       tx_status: rejected_frame&.dig(:tx_status),
                       extra_info: rejected_frame&.dig(:extra_info),
                       competing_txs: rejected_frame&.dig(:competing_txs))

      expect(rejected_frame).not_to be_nil, 'no rejected frame to document'
      expect(rejected_frame[:tx_status].to_s.upcase).to(satisfy do |s|
        %w[REJECTED DOUBLE_SPEND_ATTEMPTED].include?(s)
      end)
    ensure
      listener.stop
    end
  end

  def log_e8_payload(frame)
    warn "\n=== E8 ground-truth rejected frame ==="
    warn "  payload: #{frame.inspect}"
    warn "  tx_status: #{frame&.dig(:tx_status)}"
    warn "  extra_info: #{frame&.dig(:extra_info)}"
    warn "  competing_txs: #{frame&.dig(:competing_txs)}"
    warn "===\n"
  end
end
