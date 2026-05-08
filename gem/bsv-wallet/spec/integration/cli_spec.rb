# frozen_string_literal: true

# CLI integration tests: porcelain pipeline.
#
# Tests the unix wallet workflow: import → create → receive → balance.
# Each CLI tool runs in its own OS process, so the global Sequel::Model.db
# is scoped per-wallet — no multi-tenant issues.
#
# Environment variables (set in shell profile or CI):
#   BSV_WALLET_WIF_ALICE/BOB  — wallet private keys
#   BSV_WALLET_UTXO_ALICE     — dtxid hex of Alice's mined P2PKH UTXO
#   DATABASE_URL_ALICE/BOB    — optional, defaults to localhost:5433
#
# Run:
#   cd gem/bsv-wallet && bundle exec rspec --tag on_chain spec/integration/cli_spec.rb

require 'open3'
require 'sequel'

RSpec.describe 'CLI porcelain: create | receive pipeline', :on_chain do # rubocop:disable RSpec/DescribeClass
  let(:bin_dir) { File.expand_path('../../bin', __dir__) }
  let(:bob_identity_key) do
    require 'bsv-wallet'
    pk = BSV::Primitives::PrivateKey.from_wif(ENV.fetch('BSV_WALLET_WIF_BOB'))
    BSV::Wallet::KeyDeriver.new(private_key: pk).identity_key
  end

  before do
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
    funding_dtxid = ENV.fetch('BSV_WALLET_UTXO_ALICE')

    # Import: bootstrap Alice's wallet from root UTXO
    _stdout, _, status = run_cli('import', 'alice', funding_dtxid, '1')
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
