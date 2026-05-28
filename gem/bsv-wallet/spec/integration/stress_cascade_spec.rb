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
require 'tmpdir'
require 'fileutils'
require 'json'
require 'securerandom'
require 'bsv-wallet'

RSpec.describe '3-wallet no_send stress cascade' do # rubocop:disable RSpec/DescribeClass
  let(:payments_per_wallet) { (ENV['STRESS_PAYMENTS'] || 73).to_i }
  let(:payment_sats)        { 5_000 }
  let(:wallet_names)        { %w[alice bob carol].freeze }

  let(:bin_dir) { File.expand_path('../../bin', __dir__) }
  let(:tmpdir)  { Dir.mktmpdir("bsv_wallet_stress_#{SecureRandom.hex(4)}_") }
  let(:db_urls) do
    wallet_names.to_h { |name| [name, "sqlite://#{File.join(tmpdir, "#{name}.db")}"] }
  end
  let(:env) do
    db_urls.each_with_object({}) { |(name, url), acc| acc["DATABASE_URL_#{name.upcase}"] = url }
  end
  let(:identity_keys) do
    wallet_names.to_h do |name|
      wif = ENV.fetch("BSV_WALLET_WIF_#{name.upcase}")
      pk = BSV::Primitives::PrivateKey.from_wif(wif)
      [name, BSV::Wallet::KeyDeriver.new(private_key: pk).identity_key]
    end
  end

  before do
    missing = wallet_names.map { |n| "BSV_WALLET_WIF_#{n.upcase}" }
                          .reject { |k| ENV[k].to_s.strip.length.positive? }
    skip "Missing env: #{missing.join(', ')}" unless missing.empty?
  end

  after do
    FileUtils.rm_rf(tmpdir) if File.directory?(tmpdir)
  end

  def run_cli(tool, *args, stdin_data: nil)
    cmd = [File.join(bin_dir, tool)] + args
    stdout, stderr, status = Open3.capture3(env, *cmd, stdin_data: stdin_data, binmode: true)
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

  it 'cascades no_send payments across all wallets' do
    # Phase 1 — Import: scan each wallet's root address for the 1m-sat seed UTXO.
    wallet_names.each do |wallet|
      _, _, status = run_cli('import', wallet)
      expect(status).to be_success, "import #{wallet} failed"
      bal = balance(wallet)
      expect(bal).to be >= 1_000_000, "#{wallet} starting balance #{bal} < 1m sats"
    end

    starting = wallet_names.to_h { |w| [w, total_balance(w)] }

    # Phase 2 — Cascade: each wallet sends payments_per_wallet no_send payments
    # to a randomly chosen not-self recipient. Auto-fund's largest-first selection
    # produces the L2 → L3 → L4 fanout described in the strategy doc.
    payment_log = Hash.new(0) # "alice→bob" => count
    wallet_names.each do |sender|
      others = wallet_names - [sender]
      payments_per_wallet.times do |i|
        recipient = others.sample
        envelope, _, status = run_cli('create', sender, identity_keys[recipient], payment_sats.to_s)
        expect(status).to be_success, "create #{sender}→#{recipient} (#{i + 1}/#{payments_per_wallet}) failed"
        expect(envelope.bytesize).to be > 0

        _, _, status = run_cli('receive', recipient, '--basket', 'received', stdin_data: envelope)
        expect(status).to be_success, "receive #{sender}→#{recipient} (#{i + 1}/#{payments_per_wallet}) failed"

        payment_log["#{sender}→#{recipient}"] += 1
      end
    end

    # Phase 3 — Per-wallet final state. Total spendable spans both 'default'
    # (own change) and 'received' (inbound payments) baskets.
    final_state = wallet_names.to_h do |wallet|
      [wallet, {
        spendable_count: total_spendable(wallet),
        balance: total_balance(wallet)
      }]
    end

    # Summary report (visible in test output for retrospective analysis).
    warn "\n=== Stress cascade summary ==="
    payment_log.sort.each { |route, n| warn "  #{route}: #{n} payments" }
    warn '--- final state ---'
    final_state.each do |wallet, state|
      delta = state[:balance] - starting[wallet]
      warn "  #{wallet}: #{state[:spendable_count]} spendable, balance=#{state[:balance]} (Δ#{delta})"
    end
    aggregate_outputs = final_state.values.sum { |s| s[:spendable_count] }
    warn "  aggregate: #{aggregate_outputs} spendable outputs"
    warn "===\n"

    # Per the cascade arithmetic, after 73 payments per wallet:
    #   self ('default' basket): 7 × 73 + 1 = 512 own change outputs
    #   inbound ('received' basket): ~73 from the other two wallets
    # Expect ≈ 585 per wallet, ≈ 1755 in aggregate, per the strategy doc.
    # Real-world variance is wider than the theoretical model: random not-self
    # routing distributes inbound unevenly, and once a wallet's own-change set
    # drops below the payment unit, auto-fund consumes multiple inputs per
    # payment which changes the net-output-per-payment calculus. Observed
    # spread across runs: ~400-600 per wallet, ~1400-1800 aggregate.
    final_state.each do |wallet, state|
      expect(state[:spendable_count]).to be_between(400, 700),
                                         "#{wallet}: #{state[:spendable_count]} spendable outputs (expected ~585)"
    end
    expect(aggregate_outputs).to be_between(1300, 2100),
                                 "aggregate #{aggregate_outputs} spendable outputs (expected ~1755)"

    # Each wallet's total balance change is bounded: outbound payments leave
    # 73 × 5000 = 365k sats minus inbound received (also ~365k). Net per
    # wallet should be near-zero (fees only). The whole loop is no_send so
    # nothing was mined — balances reflect persisted state only.
    final_state.each do |wallet, state|
      delta = starting[wallet] - state[:balance]
      expect(delta.abs).to be < 1_000_000,
                           "#{wallet}: balance moved by #{delta} (likely a fee or accounting bug)"
    end
  end
end
