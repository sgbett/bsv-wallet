# frozen_string_literal: true

# CI integration stress-test: 3-wallet no_send payment cascade (HLR #129).
#
# Drives ~219 no_send payments across ALICE / BOB / CAROL using the
# "Predicted Change Fanout" pattern from .claude/strategies/Feature-testing.md.
# Each payment is 5_000 sats, recipient chosen at random (not-self), BEEF
# handed off via Engine#internalize_action.
#
# Cascade per wallet (auto-fund picks largest spendable first via
# Store#find_spendable's `ORDER BY satoshis DESC`):
#   - Payment 1     consumes the 1m-sat root → 8 change × ~124k
#   - Payments 2-9  consume each ~124k change → 8 change × ~14k each (× 8 → 64 × 14k)
#   - Payments 10-73 consume each ~14k change → 8 change × ~1.1k each (× 64 → 512 × 1.1k)
# Final per wallet: ~512 own L4 change + ~73 inbound from other wallets ≈ 585.
# Across 3 wallets: ~1755 spendable outputs.
#
# Required environment:
#   BSV_WALLET_WIF_ALICE  — Alice's wallet private key (WIF)
#   BSV_WALLET_WIF_BOB    — Bob's wallet private key (WIF)
#   BSV_WALLET_WIF_CAROL  — Carol's wallet private key (WIF)
#
# Each wallet address must hold ≥ 1_000_000 sats on chain. No payments
# are broadcast — `no_send: true` throughout — so balances do not decay.

require 'open3'
require 'json'
require 'securerandom'
require 'sequel'
require 'bsv-wallet'
require_relative '../support/fanout'

# DATABASE_URL_* / BSV_WALLET_WIF_* come from the shell environment
# (~/.zshenv locally, +env:+ blocks in CI), inherited by this spec process
# and the bin/ subprocesses it spawns alike.

RSpec.describe '3-wallet no_send stress cascade' do # rubocop:disable RSpec/DescribeClass
  let(:payments_per_wallet) { (ENV['STRESS_PAYMENTS'] || 73).to_i }
  let(:payment_sats)        { 5_000 }
  let(:wallet_names)        { %w[alice bob carol].freeze }

  let(:bin_dir) { File.expand_path('../../bin', __dir__) }
  let(:identity_keys) do
    wallet_names.to_h do |name|
      wif = BSV::Wallet::Fixtures.wallet(name.to_sym).wif
      pk = BSV::Primitives::PrivateKey.from_wif(wif)
      [name, BSV::Wallet::KeyDeriver.new(private_key: pk).identity_key]
    end
  end

  # Required: each wallet needs a WIF and a derivable DB URL through
  # the Fixtures registry (BSV_WALLET_WIF_<NAME> + BSV_WALLET_POSTGRES
  # base, or DATABASE_URL_<NAME> per-wallet override).
  before do
    BSV::Wallet::Fixtures.reset!
    BSV::Wallet::Fixtures.load_config_file!
    missing = wallet_names.reject do |n|
      w = BSV::Wallet::Fixtures.wallet(n.to_sym)
      w&.wif.to_s.strip.length.positive? && w&.database_url.to_s.strip.length.positive?
    end
    skip "Missing fixtures: #{missing.join(', ')}" unless missing.empty?

    # Per-test isolation: TRUNCATE every table in each wallet's DB so each
    # spec example starts from a clean slate.
    wallet_names.each { |w| reset_wallet_db(w) }
  end

  after { BSV::Wallet::Fixtures.reset! }

  def reset_wallet_db(wallet)
    db = Sequel.connect(BSV::Wallet::Fixtures.wallet(wallet.to_sym).database_url)
    begin
      tables = db.tables - %i[schema_migrations schema_info]
      return if tables.empty?

      if db.database_type == :postgres
        db.run("TRUNCATE TABLE #{tables.join(',')} RESTART IDENTITY CASCADE")
      else
        tables.each { |t| db[t].delete }
      end
    ensure
      db.disconnect
    end
  end

  def run_cli(tool, *args, stdin_data: nil)
    cmd = [File.join(bin_dir, tool)] + args
    # No env hash — Open3 inherits the parent's environment. The bin/
    # subprocess's CLI.boot reads DATABASE_URL_* from .env / shell env.
    stdout, stderr, status = Open3.capture3(*cmd, stdin_data: stdin_data, binmode: true)
    unless status.success?
      warn "  [#{tool} #{args.join(' ')}] failed (exit #{status.exitstatus}):"
      warn stderr.gsub(/^/, '    ')
    end
    [stdout, stderr, status]
  end

  def balance(wallet, basket: 'default')
    stdout, _, status = run_cli('balance', wallet, '--basket', basket)
    expect(status).to be_success, "balance #{wallet} (#{basket}) failed"
    stdout.strip.to_i
  end

  def list_outputs(wallet, basket: 'default', limit: 10_000)
    stdout, _, status = run_cli('list_outputs', wallet, '--basket', basket, '--limit', limit.to_s)
    expect(status).to be_success, "list_outputs #{wallet} (#{basket}) failed"
    JSON.parse(stdout, symbolize_names: true)
  end

  # Total spendable across both baskets touched by the cascade — 'default'
  # holds the wallet's own change, 'received' holds inbound payments.
  def total_spendable(wallet)
    default_outputs = list_outputs(wallet, basket: 'default')
    received_outputs = list_outputs(wallet, basket: 'received')
    (default_outputs[:total_outputs] || default_outputs[:total] || 0) +
      (received_outputs[:total_outputs] || received_outputs[:total] || 0)
  end

  def total_balance(wallet)
    balance(wallet, basket: 'default') + balance(wallet, basket: 'received')
  end

  # Action counts are the deterministic measure of cascade progress.
  # Output counts depend on random not-self routing, Benford change
  # distribution, and multi-input spends once own-change drops below
  # the payment unit — non-deterministic across runs. Action counts are
  # exact: one outbound per send_payment, one inbound per internalize.
  def action_counts(wallet)
    db = Sequel.connect(BSV::Wallet::Fixtures.wallet(wallet.to_sym).database_url)
    begin
      {
        total: db[:actions].count,
        outbound: db[:actions].where(Sequel.like(:description, 'send %')).count,
        inbound: db[:actions].where(description: 'received payment').count
      }
    ensure
      db.disconnect
    end
  end

  it 'cascades no_send payments across all wallets' do
    # Phase 1 — Import: scan each wallet's root address for the 1m-sat seed
    # UTXO. import_utxo's Phase 2 self-payment pays a small network fee for
    # the derived output, so the post-import default-basket balance is ~1m
    # sats minus a few dozen sats. Allow a 1000-sat margin to absorb fee
    # variance across SDK version bumps.
    wallet_names.each do |wallet|
      _, _, status = run_cli('import', wallet, '--no-send')
      expect(status).to be_success, "import #{wallet} failed"
      bal = balance(wallet)
      expect(bal).to be >= 999_000, "#{wallet} starting balance #{bal} < 999k sats (import likely failed)"
    end

    starting = wallet_names.to_h { |w| [w, total_balance(w)] }

    # Phase 2 — Cascade: each wallet sends payments_per_wallet no_send payments
    # to a randomly chosen not-self recipient via the shared Fanout primitive.
    # The transport here is the bin/ CLI pipeline (create | receive) — the
    # coverage #129 exists for. Auto-fund's largest-first selection produces
    # the L2 → L3 → L4 fanout described in the strategy doc.
    payment_log = Fanout.pass(
      wallets: wallet_names, count: payments_per_wallet, satoshis: payment_sats
    ) do |sender, recipient, sats, i|
      envelope, _, status = run_cli('create', sender, identity_keys[recipient], sats.to_s, '--no-send')
      expect(status).to be_success, "create #{sender}→#{recipient} (#{i + 1}/#{payments_per_wallet}) failed"
      expect(envelope.bytesize).to be > 0

      _, _, status = run_cli('receive', recipient, '--basket', 'received', stdin_data: envelope)
      expect(status).to be_success, "receive #{sender}→#{recipient} (#{i + 1}/#{payments_per_wallet}) failed"
    end

    # Phase 3 — Per-wallet final state. Action counts are deterministic
    # (every send_payment makes one outbound action; every internalize
    # makes one inbound action). Output counts are derived state and
    # vary across runs — reported for visibility, not asserted.
    final_state = wallet_names.to_h do |wallet|
      [wallet, {
        spendable_count: total_spendable(wallet),
        balance: total_balance(wallet),
        actions: action_counts(wallet)
      }]
    end

    # Summary report (visible in test output for retrospective analysis).
    warn "\n=== Stress cascade summary ==="
    payment_log.sort.each { |route, n| warn "  #{route}: #{n} payments" }
    warn '--- final state ---'
    final_state.each do |wallet, state|
      delta = state[:balance] - starting[wallet]
      a = state[:actions]
      warn "  #{wallet}: #{state[:spendable_count]} spendable, balance=#{state[:balance]} (Δ#{delta}), " \
           "actions total=#{a[:total]} out=#{a[:outbound]} in=#{a[:inbound]}"
    end
    aggregate_outputs = final_state.values.sum { |s| s[:spendable_count] }
    total_outbound   = final_state.values.sum { |s| s[:actions][:outbound] }
    total_inbound    = final_state.values.sum { |s| s[:actions][:inbound] }
    warn "  aggregate: #{aggregate_outputs} spendable outputs, " \
         "#{total_outbound} outbound + #{total_inbound} inbound actions"
    warn "===\n"

    # Deterministic action-count invariants.
    #
    # Each sender makes exactly +payments_per_wallet+ outbound
    # +send_payment+ calls. Each one produces exactly one outbound action
    # on the sender's wallet and exactly one inbound +internalize_action+
    # on the recipient's wallet. The system conserves: sum(outbound) ==
    # sum(inbound) == +payments_per_wallet * wallet_names.length+ exactly.
    #
    # Output counts are derived from the cascade's selection / Benford /
    # multi-input dynamics and vary across runs — they're reported above
    # but not asserted.
    expected_payments = payments_per_wallet * wallet_names.length
    final_state.each do |wallet, state|
      expect(state[:actions][:outbound]).to eq(payments_per_wallet),
                                            "#{wallet}: #{state[:actions][:outbound]} outbound actions (expected #{payments_per_wallet})"
    end
    expect(total_outbound).to eq(expected_payments)
    expect(total_inbound).to eq(expected_payments)

    # Balance conservation — the whole loop is no_send so nothing was
    # mined; the wallet's view of its balance shifts only by fees. Per
    # wallet the magnitude is bounded by the sat volume in flight.
    final_state.each do |wallet, state|
      delta = starting[wallet] - state[:balance]
      expect(delta.abs).to be < 1_000_000,
                           "#{wallet}: balance moved by #{delta} (likely a fee or accounting bug)"
    end
  end
end
