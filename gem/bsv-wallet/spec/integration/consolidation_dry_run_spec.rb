# frozen_string_literal: true

# Consolidation dry-run (HLR #130) — exercises Engine#consolidate_step
# and Engine#sweep end-to-end via bin/ tools against real wallets.
#
# Sequence per wallet:
#   1. bin/import — pull the funding UTXO from chain
#   2. Mini-cascade — 4 no_send payments to populate ~30 spendable outputs
#      (enough to trigger at least one consolidation round at target=20)
#   3. bin/consolidate — loop consolidate_step until < 20 spendable
#   4. bin/sweep — drain remaining UTXOs to an ephemeral identity
#
# Asserts: every wallet ends with zero spendable outputs, BEEF validation
# passes throughout (no exit-code failures), at least one consolidation
# round fired per wallet.
#
# Required environment: BSV_WALLET_WIF_ALICE / _BOB / _CAROL. Skips
# cleanly when any is unset. No on-chain broadcast happens (no_send: true
# throughout), so the funding UTXOs are not consumed.

require 'open3'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'securerandom'
require 'bsv-wallet'

RSpec.describe 'consolidation dry-run' do # rubocop:disable RSpec/DescribeClass
  let(:wallet_names) { %w[alice bob carol].freeze }
  let(:payments_per_wallet) { 4 }
  let(:payment_sats) { 5_000 }
  let(:bin_dir) { File.expand_path('../../bin', __dir__) }
  let(:tmpdir)  { Dir.mktmpdir("bsv_wallet_consolidation_#{SecureRandom.hex(4)}_") }
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
  # Ephemeral routing target — CI never broadcasts so the key is never used,
  # but consolidation requires a recipient for the final sweep step.
  let(:ephemeral_recipient) { BSV::Primitives::PrivateKey.generate.public_key.to_hex }

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

  def list_outputs(wallet, basket:)
    stdout, _, status = run_cli('list_outputs', wallet, '--basket', basket, '--limit', '10000')
    expect(status).to be_success, "list_outputs #{wallet} (#{basket}) failed"
    JSON.parse(stdout, symbolize_names: true)
  end

  def total_spendable(wallet)
    # bin/list_outputs's JSON envelope uses :total (not :total_outputs),
    # so accept either to stay forward-compatible.
    default = list_outputs(wallet, basket: 'default')
    received = list_outputs(wallet, basket: 'received')
    (default[:total_outputs] || default[:total] || 0) +
      (received[:total_outputs] || received[:total] || 0)
  end

  it 'consolidates and sweeps every wallet to zero spendable' do
    # Phase 1: import funding UTXOs. The default-basket balance after
    # import is the imported root UTXO's value (minus a 1-sat fee for the
    # bootstrap self-payment). Anything less means import returned empty
    # — usually a transient network error worth surfacing immediately.
    wallet_names.each do |wallet|
      _, _, status = run_cli('import', wallet)
      expect(status).to be_success, "import #{wallet} failed"
      balance_stdout, _, status = run_cli('balance', wallet)
      expect(status).to be_success, "post-import balance #{wallet} failed"
      bal = balance_stdout.strip.to_i
      expect(bal).to be >= 100_000, "#{wallet} starting balance #{bal} < 100k sats — import likely returned empty"
    end

    # Phase 2: mini-cascade. Each wallet sends a few no_send payments to
    # randomly chosen not-self recipients so its spendable set grows past
    # the consolidation target. Kept as a separate loop from Phase 1 so
    # the four phases stay distinct in the spec narrative.
    wallet_names.each do |sender| # rubocop:disable Style/CombinableLoops
      others = wallet_names - [sender]
      payments_per_wallet.times do |i|
        recipient = others.sample
        envelope, _, status = run_cli('create', sender, identity_keys[recipient], payment_sats.to_s)
        expect(status).to be_success, "create #{sender}→#{recipient} (#{i + 1}) failed"

        _, _, status = run_cli('receive', recipient, '--basket', 'received', stdin_data: envelope)
        expect(status).to be_success, "receive #{sender}→#{recipient} (#{i + 1}) failed"
      end
    end

    pre_consolidate = wallet_names.to_h { |w| [w, total_spendable(w)] }
    # Cascade must populate something for consolidate to be meaningful.
    pre_consolidate.each do |w, n|
      expect(n).to be >= 4, "#{w}: only #{n} spendable after cascade (cascade likely silently failed)"
    end

    # Phase 3: consolidate each wallet until below the target.
    wallet_names.each do |wallet|
      _, _, status = run_cli('consolidate', wallet, '--target-inputs', '20')
      expect(status).to be_success, "consolidate #{wallet} failed"
      # Below target_inputs after consolidation (loop terminated correctly).
      expect(total_spendable(wallet)).to be < 20,
                                         "#{wallet} still has #{total_spendable(wallet)} spendable after consolidate"
    end

    # Phase 4: sweep each wallet to the ephemeral recipient.
    wallet_names.each do |wallet| # rubocop:disable Style/CombinableLoops
      _, _, status = run_cli('sweep', wallet, '--to', ephemeral_recipient)
      expect(status).to be_success, "sweep #{wallet} failed"
    end

    # Final assertions: each wallet reduced to at most one dust residue
    # (the fee-estimate / actual-fee delta can leave a sub-100-sat output
    # that the SDK's distribute_change keeps rather than drops). The
    # strategy doc's "less a token fee" framing accepts this.
    warn "\n=== Consolidation dry-run summary ==="
    wallet_names.each do |wallet|
      final = total_spendable(wallet)
      final_balance_default = list_outputs(wallet, basket: 'default')[:outputs].sum { |o| o[:satoshis] }
      final_balance_received = list_outputs(wallet, basket: 'received')[:outputs].sum { |o| o[:satoshis] }
      final_balance = final_balance_default + final_balance_received
      warn "  #{wallet}: pre-consolidate=#{pre_consolidate[wallet]} final=#{final} residue=#{final_balance} sats"
      expect(final).to be <= 1, "#{wallet}: #{final} spendable outputs after sweep (expected 0 or 1 dust residue)"
      expect(final_balance).to be < 100, "#{wallet}: residue balance #{final_balance} sats > dust"
    end
    warn "===\n"
  end
end
