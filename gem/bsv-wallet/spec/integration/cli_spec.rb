# frozen_string_literal: true

# CLI integration test for the wallet bin tools.
#
# Exercises the porcelain pipeline (import → balance → create → receive
# → balance) end-to-end against real wallets with real on-chain UTXOs.
# Reads from the BSV network for UTXO discovery and merkle proof
# verification; uses no_send throughout — nothing is broadcast.
#
# Required environment:
#   BSV_WALLET_WIF_ALICE        — Alice's wallet private key (WIF)
#   BSV_WALLET_WIF_BOB          — Bob's wallet private key (WIF)
#   DATABASE_URL_ALICE          — Alice's database (default: postgres://...localhost:5433/bsv_wallet_alice)
#   DATABASE_URL_BOB            — Bob's database (default: postgres://...localhost:5433/bsv_wallet_bob)
#
# Alice's address must hold >= 1_000_000 sats (1m sats) on chain. Top up
# out-of-band before running for the first time; the test consumes a
# small payment per run but uses no_send so balance shouldn't decrease.

require 'open3'
require 'sequel'

RSpec.describe 'CLI porcelain: create | receive pipeline' do # rubocop:disable RSpec/DescribeClass
  let(:bin_dir) { File.expand_path('../../../bin', __dir__) }
  let(:bob_identity_key) do
    require 'bsv-wallet'
    pk = BSV::Primitives::PrivateKey.from_wif(ENV.fetch('BSV_WALLET_WIF_BOB'))
    BSV::Wallet::KeyDeriver.new(private_key: pk).identity_key
  end

  before do
    missing = %w[BSV_WALLET_WIF_ALICE BSV_WALLET_WIF_BOB].reject { |k| ENV.fetch(k, nil) }
    unless missing.empty?
      raise <<~MSG
        Integration test setup incomplete. Missing environment variables:
          #{missing.join("\n  ")}

        Required: BSV_WALLET_WIF_ALICE, BSV_WALLET_WIF_BOB
        Optional: DATABASE_URL_ALICE, DATABASE_URL_BOB (default to localhost:5433/bsv_wallet_alice|bob)

        Alice's wallet address must hold >= 1_000_000 sats on chain
        before this test will pass. Fund it once out-of-band — the test
        uses no_send and shouldn't decrease the balance per run.
      MSG
    end

    # Clean slate — other specs may have used these databases
    %w[DATABASE_URL_ALICE DATABASE_URL_BOB].each do |env_key|
      url = ENV.fetch(env_key, "postgres://postgres:postgres@localhost:5433/bsv_wallet_#{env_key.split('_').last.downcase}")
      db = Sequel.connect(url)
      db.tables.each { |t| db[t].truncate(cascade: true) unless t == :schema_info }
      db.disconnect
    end
  end

  def run_cli(tool, *args, stdin_data: nil)
    cmd = [File.join(bin_dir, tool)] + args
    stdout, stderr, status = Open3.capture3({}, *cmd, stdin_data: stdin_data, binmode: true)
    unless status.success?
      warn "  [#{tool}] failed (exit #{status.exitstatus}):"
      warn stderr.gsub(/^/, '    ')
    end
    [stdout, stderr, status]
  end

  it 'Alice pays Bob via create | receive pipeline' do
    # Import: scan Alice's root key address for UTXOs
    _stdout, _, status = run_cli('import', 'alice')
    expect(status).to be_success

    # Balance: verify Alice has funds
    stdout, _stderr, status = run_cli('balance', 'alice')
    expect(status).to be_success
    alice_balance = stdout.strip.to_i
    expect(alice_balance).to be > 0

    # Create: Alice pays Bob 5000 sats (outputs JSON envelope)
    envelope_stdout, _, status = run_cli('create', 'alice', bob_identity_key, '5000')
    expect(status).to be_success
    expect(envelope_stdout.bytesize).to be > 0

    # Receive: Bob internalizes the payment
    _stdout, _, status = run_cli('receive', 'bob', '--basket', 'received', stdin_data: envelope_stdout)
    expect(status).to be_success

    # Balance: verify Bob received 5000 sats
    stdout, _stderr, status = run_cli('balance', 'bob', '--basket', 'received')
    expect(status).to be_success
    expect(stdout.strip.to_i).to eq(5000)

    # Balance: verify Alice's balance decreased
    stdout, _stderr, status = run_cli('balance', 'alice')
    expect(status).to be_success
    new_alice_balance = stdout.strip.to_i
    # Auto-fund computes the real fee; change is returned across multiple outputs
    expect(new_alice_balance).to be < alice_balance
    expect(new_alice_balance).to be > alice_balance - 5000 - 500 # fee is well under 500
  end
end
