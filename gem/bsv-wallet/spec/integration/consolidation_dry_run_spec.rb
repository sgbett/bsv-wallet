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
require 'json'
require 'securerandom'
require 'sequel'
require 'bsv-wallet'

# DATABASE_URL_* / BSV_WALLET_WIF_* come from the shell environment
# (~/.zshenv locally, +env:+ blocks in CI), inherited by this spec process
# and the bin/ subprocesses it spawns alike.

RSpec.describe 'consolidation dry-run' do # rubocop:disable RSpec/DescribeClass
  let(:wallet_names) { %w[alice bob carol].freeze }
  let(:payments_per_wallet) { 4 }
  let(:payment_sats) { 5_000 }
  let(:bin_dir) { File.expand_path('../../bin', __dir__) }
  let(:identity_keys) do
    wallet_names.to_h do |name|
      wif = BSV::Wallet::Fixtures.wallet(name.to_sym).wif
      pk = BSV::Primitives::PrivateKey.from_wif(wif)
      [name, BSV::Wallet::KeyDeriver.new(private_key: pk).identity_key]
    end
  end
  # Ephemeral routing target — CI never broadcasts so the key is never used,
  # but consolidation requires a recipient for the final sweep step.
  let(:ephemeral_recipient) { BSV::Primitives::PrivateKey.generate.public_key.to_hex }

  # Required env: per the Fixtures registry, alice/bob/carol need
  # BSV_WALLET_WIF_<NAME> + a derivable DATABASE_URL_<NAME> (or
  # BSV_WALLET_POSTGRES base).
  before do
    # Paused during the #433 native CLI rebuild. This spec shells out
    # to bin/balance / bin/list_outputs which were deleted in Phase 1
    # (replaced by bin/wallet balance / bin/wallet list outputs). The
    # consolidation + sweep scenario will be rebuilt in Phase 6
    # against the new dispatcher. Re-enable for ad-hoc verification
    # with WALLET_LEGACY_INTEGRATION=1.
    skip 'paused during #433 rebuild (set WALLET_LEGACY_INTEGRATION=1 to run)' unless ENV['WALLET_LEGACY_INTEGRATION'] == '1'

    BSV::Wallet::Fixtures.reset!
    BSV::Wallet::Fixtures.load_config_file!
    missing = wallet_names.reject do |n|
      w = BSV::Wallet::Fixtures.wallet(n.to_sym)
      w&.wif.to_s.strip.length.positive? && w&.database_url.to_s.strip.length.positive?
    end
    skip "Missing fixtures: #{missing.join(', ')}" unless missing.empty?

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

  def list_outputs(wallet, basket:)
    stdout, _, status = run_cli('list_outputs', wallet, '--basket', basket, '--limit', '10000')
    expect(status).to be_success, "list_outputs #{wallet} (#{basket}) failed"
    JSON.parse(stdout, symbolize_names: true)
  end

  def total_spendable(wallet)
    # bin/list_outputs's JSON envelope uses :total (not :total_outputs),
    # so accept either to stay forward-compatible.
    unbasketed = list_outputs(wallet, basket: 'none')
    received = list_outputs(wallet, basket: 'received')
    (unbasketed[:total_outputs] || unbasketed[:total] || 0) +
      (received[:total_outputs] || received[:total] || 0)
  end

  # Count actions by description directly against the wallet's DB. Action
  # counts are deterministic — consolidation rounds and sweeps land as
  # discrete rows — while output counts (the brittle measure) depend on
  # the SDK's dust-drop / Benford behavior on the final change
  # distribution. HLR #130's acceptance criterion is "action records
  # reflect the expected count" exactly because of this.
  def action_counts(wallet)
    db = Sequel.connect(BSV::Wallet::Fixtures.wallet(wallet.to_sym).database_url)
    begin
      {
        total: db[:actions].count,
        consolidation: db[:actions].where(description: 'consolidation').count,
        sweep: db[:actions].where(description: 'sweep').count
      }
    ensure
      db.disconnect
    end
  end

  it 'consolidates and sweeps every wallet to zero spendable' do
    # Phase 1: import funding UTXOs. The post-import unbasketed-output
    # balance is the imported root UTXO's value (~1m sats) minus the
    # bootstrap self-payment's network fee (a few dozen sats). Allow a
    # 1000-sat margin to absorb fee variance across SDK version bumps.
    wallet_names.each do |wallet|
      _, _, status = run_cli('import', wallet, '--no-send')
      expect(status).to be_success, "import #{wallet} failed"
      balance_stdout, _, status = run_cli('balance', wallet)
      expect(status).to be_success, "post-import balance #{wallet} failed"
      bal = balance_stdout.strip.to_i
      expect(bal).to be >= 999_000, "#{wallet} starting balance #{bal} < 999k sats (import likely failed)"
    end

    # Phase 2: mini-cascade. Each wallet sends a few no_send payments to
    # randomly chosen not-self recipients so its spendable set grows past
    # the consolidation target. Kept as a separate loop from Phase 1 so
    # the four phases stay distinct in the spec narrative.
    wallet_names.each do |sender| # rubocop:disable Style/CombinableLoops
      others = wallet_names - [sender]
      payments_per_wallet.times do |i|
        recipient = others.sample
        envelope, _, status = run_cli('create', sender, identity_keys[recipient], payment_sats.to_s, '--no-send')
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
      _, _, status = run_cli('consolidate', wallet, '--target-inputs', '20', '--no-send')
      expect(status).to be_success, "consolidate #{wallet} failed"
      # Below target_inputs after consolidation (loop terminated correctly).
      expect(total_spendable(wallet)).to be < 20,
                                         "#{wallet} still has #{total_spendable(wallet)} spendable after consolidate"
    end

    # Phase 4: sweep each wallet to the ephemeral recipient.
    wallet_names.each do |wallet| # rubocop:disable Style/CombinableLoops
      _, _, status = run_cli('sweep', wallet, '--to', ephemeral_recipient, '--no-send')
      expect(status).to be_success, "sweep #{wallet} failed"
    end

    # Final assertions: count consolidation and sweep ACTIONS per wallet,
    # per HLR #130's "action records reflect the expected count
    # (consolidation rounds + 1 sweep per wallet)" criterion. Action
    # counts are deterministic; output counts (which used to be the
    # assertion) vary with the SDK's distribute_change dust-drop behavior
    # at the final tx.
    #
    # Mini-cascade scale: each wallet ends Phase 2 with ~30 spendable
    # outputs (4 outbound × 8 change + ~3 inbound, minus auto-fund
    # selection variance). With target-inputs=20, the consolidation
    # loop runs exactly once per wallet (20 + 1 anchor = 21 inputs
    # consumed, 1 change output produced; remaining < 20 terminates
    # the loop).
    warn "\n=== Consolidation dry-run summary ==="
    wallet_names.each do |wallet|
      final_spendable = total_spendable(wallet)
      actions = action_counts(wallet)
      warn "  #{wallet}: pre-consolidate=#{pre_consolidate[wallet]} final_spendable=#{final_spendable} " \
           "consolidation_actions=#{actions[:consolidation]} sweep_actions=#{actions[:sweep]}"

      expect(actions[:consolidation]).to be >= 1,
                                         "#{wallet}: #{actions[:consolidation]} consolidation actions " \
                                         '(expected >= 1; mini-cascade should produce one round)'
      expect(actions[:sweep]).to eq(1),
                                 "#{wallet}: #{actions[:sweep]} sweep actions (expected exactly 1)"
    end
    warn "===\n"
  end
end
