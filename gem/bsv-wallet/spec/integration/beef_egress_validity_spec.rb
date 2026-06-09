# frozen_string_literal: true

# Diagnostic spec for #296 Phase A — BEEF egress validity.
#
# Asserts the SPV honesty contract at the wallet's outgoing-BEEF boundary:
# any BEEF the wallet emits for wallet→wallet handoff must be structurally
# complete, i.e. a recipient with no prior knowledge can verify it.
#
# The wallet currently fails this contract intermittently — bin/import's
# proof acquisition (Engine#fetch_and_link_proof) silently no-ops when WoC
# does not return `blockheight`, leaving the imported UTXO's merkle_path
# missing from tx_proofs. A subsequent send_payment then walks
# Action#wire_ancestor over the incomplete proof state, emits a BEEF whose
# seed UTXO is a RawTxEntry (no BUMP), and ships it. The receiver's verify
# raises `missing_source` three layers downstream.
#
# This spec catches that asymmetry at the egress boundary by verifying the
# wallet's outgoing BEEF against a structural-only chain_tracker (AlwaysValid)
# whose only role is to neutralise the on-chain header check so the test
# fails on structural completeness alone.
#
# Today this spec FAILS — sometimes on the headline assertion (when WoC
# flakes and the seed merkle_path doesn't get acquired), sometimes on the
# supporting assertion (which catches the same condition deterministically
# from the tx_proofs side). After #296 Phase B's fix (strict import +
# validate_for_handoff! precondition on create_action), it PASSES.

require 'open3'
require 'json'
require 'sequel'
require 'bsv-wallet'

# Structural-only chain tracker. Says yes to every merkle root lookup so
# the BEEF's verify check fails on *structural* completeness alone (a
# missing source_transaction wiring), not on on-chain validity.
class AlwaysValidChainTracker < BSV::Transaction::ChainTracker
  def initialize = super(nil)
  def valid_root_for_height?(_root, _height) = true
  def current_height = 1_000_000
end

RSpec.describe 'BEEF egress validity' do # rubocop:disable RSpec/DescribeClass
  let(:bin_dir) { File.expand_path('../../bin', __dir__) }
  let(:alice_db_url) { BSV::Wallet::Fixtures.wallet(:alice).database_url }
  let(:bob_identity_key) do
    wif = BSV::Wallet::Fixtures.wallet(:bob).wif
    BSV::Wallet::KeyDeriver.new(private_key: BSV::Primitives::PrivateKey.from_wif(wif)).identity_key
  end

  before do
    BSV::Wallet::Fixtures.reset!
    BSV::Wallet::Fixtures.load_config_file!
    %i[alice bob].each do |name|
      w = BSV::Wallet::Fixtures.wallet(name)
      skip "Missing fixture: #{name}" unless w&.wif.to_s.strip.length.positive? &&
                                             w&.database_url.to_s.strip.length.positive?
    end
    %w[alice bob].each { |w| reset_wallet_db(w) }
  end

  after { BSV::Wallet::Fixtures.reset! }

  def reset_wallet_db(wallet)
    db = Sequel.connect(BSV::Wallet::Fixtures.wallet(wallet.to_sym).database_url)
    tables = db.tables - %i[schema_migrations schema_info]
    db.run("TRUNCATE TABLE #{tables.join(',')} RESTART IDENTITY CASCADE") if tables.any?
  ensure
    db&.disconnect
  end

  def run_cli(tool, *args, stdin_data: nil)
    cmd = [File.join(bin_dir, tool)] + args
    stdout, stderr, status = Open3.capture3(*cmd, stdin_data: stdin_data, binmode: true)
    expect(status).to be_success, "[#{tool} #{args.join(' ')}] failed: #{stderr}"
    stdout
  end

  describe 'after alice imports a confirmed UTXO from chain' do
    it 'every root output in alice.spendable has a merkle_path in tx_proofs' do
      run_cli('import', 'alice', '--no-send')

      alice_db = Sequel.connect(alice_db_url)
      begin
        root_actions = alice_db[:actions].where(description: 'imported UTXO').all
        expect(root_actions).not_to be_empty,
                                    "import produced no 'imported UTXO' actions — bin/import failed silently"

        root_actions.each do |action|
          proof = alice_db[:tx_proofs].where(wtxid: Sequel.blob(action[:wtxid])).first
          dtxid = action[:wtxid].reverse.unpack1('H*')

          expect(proof).not_to be_nil,
                               "imported root tx #{dtxid} has no row in tx_proofs"
          expect(proof[:merkle_path]).not_to be_nil,
                                             "imported root tx #{dtxid} has no merkle_path — " \
                                             'fetch_and_link_proof silently no-op (likely WoC blockheight miss). ' \
                                             'Under the strict-import contract, this should refuse the import outright.'
        end
      ensure
        alice_db.disconnect
      end
    end
  end

  describe 'alice → bob send_payment' do
    it 'produces a BEEF that verifies against a structural-only chain_tracker' do
      run_cli('import', 'alice', '--no-send')
      envelope_json = run_cli('create', 'alice', bob_identity_key, '5000', '--no-send')
      envelope = JSON.parse(envelope_json, symbolize_names: true)
      beef_bytes = [envelope[:beef]].pack('H*')

      beef = BSV::Transaction::Beef.from_binary(beef_bytes)
      subject_wtxid = [envelope[:dtxid]].pack('H*').reverse
      subject_entry = beef.transactions.find { |e| e.wtxid == subject_wtxid }
      expect(subject_entry).not_to be_nil, "subject #{envelope[:dtxid]} missing from emitted BEEF"
      expect(subject_entry.transaction).not_to be_nil, 'subject BEEF entry has no transaction object'

      # The headline contract: a peer with no prior knowledge of alice's
      # state can verify the BEEF using only what alice carried in it.
      # AlwaysValidChainTracker neutralises the on-chain header check so a
      # failure here is structural — a missing source_transaction wiring,
      # an unwired unconfirmed ancestor, etc. Exactly what bob's verify
      # would catch — moved to alice's egress.
      expect do
        subject_entry.transaction.verify(chain_tracker: AlwaysValidChainTracker.new)
      end.not_to raise_error
    end
  end
end
