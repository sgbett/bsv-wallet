# frozen_string_literal: true

# Phase 2 of the #126 e2e on-chain harness — initial fragmentation.
#
# Builds on Phase 1's funded state: each wallet holds a single 10m-sat
# output. Drives a 5-level +no_send: true+ cascade per wallet, scaled
# 10× over the CI stress cascade (#129):
#
#   L2-L4 (73 outbound 50k-sat payments per wallet)
#     The wallet's auto-fund picks largest-first. The strict magnitude
#     ordering — 10m root > 1.243m L2 change > 149k L3 change > 50k
#     inbound > 12k L4 change — means each layer's own change is always
#     larger than any inbound from other wallets, so the cascade
#     resolves cleanly even with concurrent inbound payments. 73 =
#     1 (L2) + 8 (L3) + 64 (L4), driven entirely by largest-first.
#
#   L5 (73 outbound 12k-sat payments per wallet)
#     After L2-L4 across all wallets, each wallet holds ~512 × 12k own
#     change + ~73 × 50k inbound. 50k is now the largest, so L5
#     auto-funds each payment from a single inbound — producing 1 × 12k
#     outbound + 8 × ~4700 change per L5 tx. End state per wallet:
#     ~512 L4 change (12k) + ~73 L5 inbound (12k) + ~584 L5 change
#     (~4700) ≈ 1169 spendable outputs.
#
# All payments are +no_send: true+ — nothing reaches ARC. The BEEF
# from each +send_payment+ is handed to the recipient's
# +internalize_action+ immediately, building a peer-to-peer fanout
# ready for Phase 3's broadcast loop.
#
# Restart safety: this phase is destructive in the sense that it
# fragments Phase 1's 10m outputs, so re-running requires re-running
# Phase 1 first (which re-drains + re-funds).

require_relative 'spec_helper'
require_relative '../support/fanout'

RSpec.describe 'e2e Phase 2 — initial fragmentation (no_send)' do # rubocop:disable RSpec/DescribeClass
  let(:l4_payments) { (ENV['FRAG_L4_PAYMENTS'] || 73).to_i }
  let(:l5_payments) { (ENV['FRAG_L5_PAYMENTS'] || 73).to_i }
  let(:l4_satoshis) { (ENV['FRAG_L4_SATS'] || 50_000).to_i }
  let(:l5_satoshis) { (ENV['FRAG_L5_SATS'] || 12_000).to_i }
  let(:received_basket) { 'received' }

  before do
    missing = E2E::WalletHarness.missing_env
    skip "Phase 2 requires env: #{missing.join(', ')}" unless missing.empty?
    E2E::EventLog.start
  end

  after { E2E::EventLog.stop }

  # Internalize +payment+ at the recipient. Uses the 'basket insertion'
  # protocol so the output lands in +received_basket+ alongside its
  # BRC-42 derivation context — matches the +bin/receive+ pattern used
  # by the CI cascade specs.
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

  # Drive one +Fanout.pass+ over +ctxs+ with the in-process engine
  # transport: each hop is a no_send +send_payment+ internalized at the
  # recipient. +level+ labels the cascade tier for the event stream and
  # the inbound action description. Returns the per-route count Hash.
  def cascade_pass!(ctxs, count:, satoshis:, level:)
    Fanout.pass(wallets: ctxs.keys, count: count, satoshis: satoshis) do |sender, recipient, sats, i|
      payment = ctxs[sender][:engine].send_payment(
        recipient: ctxs[recipient][:key_deriver].identity_key,
        satoshis: sats
        # no_send: true is the default — see Engine#send_payment.
      )
      internalize_at(ctxs[recipient], payment, description: "#{level} fragment")
      BSV::Wallet.emit("e2e.frag.#{level}",
                       from: sender, to: recipient, satoshis: sats, i: i + 1)
    end
  end

  it 'fragments each wallet via the 5-level no_send cascade' do
    BSV::Wallet.emit('e2e.phase2.start',
                     l4_payments: l4_payments, l4_satoshis: l4_satoshis,
                     l5_payments: l5_payments, l5_satoshis: l5_satoshis)

    # Boot in-process engines for the five test wallets. SDK doesn't
    # participate in fragmentation — Phase 1 already funded each Wn.
    E2E::WalletHarness.install_derived_wifs!
    test_ctxs = E2E::WalletHarness.test_wallet_names.to_h do |name|
      [name, E2E::WalletHarness.boot(name)]
    end

    starting = test_ctxs.transform_values { |ctx| ctx[:utxo_pool].balance }
    BSV::Wallet.emit('e2e.phase2.balances.start',
                     total: starting.values.sum, wallets: starting.length)

    # Pass 1: L2-L4 — 73 outbound 50k-sat payments per wallet.
    l4_log = cascade_pass!(test_ctxs, count: l4_payments,
                                      satoshis: l4_satoshis, level: 'l4')

    # Pass 2: L5 — 73 outbound 12k-sat payments per wallet. By now the
    # 50k inbound from pass 1 are the largest spendable on each wallet;
    # auto-fund picks them, producing 12k payment + ~4700-sat change.
    l5_log = cascade_pass!(test_ctxs, count: l5_payments,
                                      satoshis: l5_satoshis, level: 'l5')

    # Final state report. Output counts depend on Benford distribution
    # at change generation; action counts are deterministic.
    final = test_ctxs.to_h do |name, ctx|
      out_db = Sequel.connect(ENV.fetch("DATABASE_URL_#{name.upcase}"))
      begin
        actions = {
          total: out_db[:actions].count,
          outbound: out_db[:actions].where(Sequel.like(:description, 'send %')).count,
          inbound: out_db[:actions].where(Sequel.like(:description, '% fragment')).count
        }
      ensure
        out_db.disconnect
      end
      [name, {
        spendable_count: ctx[:utxo_pool].spendable_count,
        balance: ctx[:utxo_pool].balance,
        actions: actions
      }]
    end

    warn "\n=== Fragmentation summary ==="
    warn "  L4 routes: #{l4_log.sort.map { |r, n| "#{r}=#{n}" }.join(' ')}"
    warn "  L5 routes: #{l5_log.sort.map { |r, n| "#{r}=#{n}" }.join(' ')}"
    final.each do |w, s|
      a = s[:actions]
      warn "  #{w}: spendable=#{s[:spendable_count]} balance=#{s[:balance]} " \
           "actions total=#{a[:total]} out=#{a[:outbound]} in=#{a[:inbound]}"
    end
    warn "===\n"
    BSV::Wallet.emit('e2e.phase2.complete',
                     total_spendable: final.values.sum { |s| s[:spendable_count] })

    # Deterministic action-count invariants. Each wallet sent exactly
    # +l4_payments+ + +l5_payments+ outbound actions. Sum of outbound
    # == sum of inbound across the five wallets (every send produces
    # exactly one internalize at the recipient).
    expected_outbound_per_wallet = l4_payments + l5_payments
    final.each do |w, s|
      expect(s[:actions][:outbound]).to eq(expected_outbound_per_wallet),
                                        "#{w}: #{s[:actions][:outbound]} outbound actions " \
                                        "(expected #{expected_outbound_per_wallet})"
    end

    total_outbound = final.values.sum { |s| s[:actions][:outbound] }
    total_inbound  = final.values.sum { |s| s[:actions][:inbound] }
    expect(total_outbound).to eq(total_inbound),
                              "outbound=#{total_outbound} != inbound=#{total_inbound} (BEEF handoff lost)"

    # Spendable count sanity: each wallet should have well over the
    # 512-output baseline (L4 change) plus some L5 fragments. The
    # exact number varies (Benford / dust-drop), so we only check
    # ">= 500" as a lower bound that proves cascade actually ran.
    final.each do |w, s|
      expect(s[:spendable_count]).to be >= 500,
                                     "#{w}: only #{s[:spendable_count]} spendable after fragmentation"
    end
  end
end
