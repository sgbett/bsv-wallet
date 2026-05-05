# frozen_string_literal: true

# CLI integration tests: Alice sends BSV to Bob via separate processes.
#
# Each CLI tool runs in its own OS process, so the global Sequel::Model.db
# is scoped per-wallet — no multi-tenant issues.
#
# Environment variables (set in shell profile or CI):
#   WIF_ALICE, WIF_BOB       — wallet private keys
#   FUNDING_TXID              — dtxid hex of Alice's mined P2PKH UTXO
#   DATABASE_URL_ALICE/BOB    — optional, defaults to localhost:5433
#
# Run:
#   cd gem/bsv-wallet && bundle exec rspec --tag on_chain spec/integration/cli_spec.rb

require 'open3'

RSpec.describe 'CLI integration: Alice sends to Bob', :on_chain do
  let(:bin_dir) { File.expand_path('../../bin', __dir__) }

  # Derive Bob's identity key from WIF without a database connection
  let(:bob_identity_key) do
    require 'bsv-wallet'
    pk = BSV::Primitives::PrivateKey.from_wif(ENV.fetch('WIF_BOB'))
    BSV::Wallet::KeyDeriver.new(private_key: pk).identity_key
  end

  def run_cli(tool, *args, stdin_data: nil)
    cmd = [File.join(bin_dir, tool)] + args
    env = {} # inherits parent env
    stdout, stderr, status = Open3.capture3(env, *cmd, stdin_data: stdin_data, binmode: true)
    unless status.success?
      $stderr.puts "  [#{tool}] failed (exit #{status.exitstatus}):"
      $stderr.puts stderr.gsub(/^/, '    ')
    end
    [stdout, stderr, status]
  end

  it 'Alice pays Bob via CLI pipeline' do
    # 0. Import the funding UTXO
    funding_dtxid = ENV.fetch('FUNDING_TXID')
    _stdout, stderr, status = run_cli('import_root_utxo', 'alice', funding_dtxid, '0')
    expect(status).to be_success
    puts "\n  Import: #{stderr.strip}"

    # 1. Verify Alice has funds
    stdout, _stderr, status = run_cli('balance', 'alice')
    expect(status).to be_success
    alice_balance = stdout.strip.to_i
    expect(alice_balance).to be > 0
    puts "  Alice balance: #{alice_balance} sats"

    # 2. Alice sends 500 sats to Bob (no_send — outputs BEEF to stdout)
    beef_stdout, stderr, status = run_cli(
      'send', 'alice', '--to', bob_identity_key, '--sats', '500'
    )
    expect(status).to be_success
    expect(beef_stdout.bytesize).to be > 0
    puts "  Send: #{stderr.strip.gsub("\n", "\n  ")}"

    # 3. Bob receives the BEEF
    _stdout, stderr, status = run_cli('receive', 'bob', stdin_data: beef_stdout)
    expect(status).to be_success
    puts "  Receive: #{stderr.strip}"

    # 4. Verify Bob's balance in 'received' basket
    stdout, _stderr, status = run_cli('balance', 'bob', '--basket', 'received')
    expect(status).to be_success
    bob_balance = stdout.strip.to_i
    expect(bob_balance).to eq(500)
    puts "  Bob received: #{bob_balance} sats"

    # 5. Verify Alice's change returned
    stdout, _stderr, status = run_cli('balance', 'alice')
    expect(status).to be_success
    new_alice_balance = stdout.strip.to_i
    expect(new_alice_balance).to eq(alice_balance - 500 - 226)
    puts "  Alice remaining: #{new_alice_balance} sats"
  end
end
