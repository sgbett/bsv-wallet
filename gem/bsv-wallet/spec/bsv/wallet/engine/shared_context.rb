# frozen_string_literal: true

require 'securerandom'

# Shared setup for engine specs.
#
# The engine spec suite runs against the default wallet store (SQLite).
# It piggybacks on the wallet gem's store shared_context for db
# connection, schema migration, and model binding — both sets of specs
# touch BSV::Wallet::Store::Models::* models, so they must share the same
# Sequel::Database instance.
#
# Usage:
#   RSpec.describe BSV::Wallet::Engine do
#     include_context 'engine setup'
#     ...
#   end

require 'bsv-wallet'
require_relative '../store/shared_context'

# Constants at top level so they're accessible as bare constants in specs.
OP_TRUE = "\x51".b.freeze unless defined?(OP_TRUE)
unless defined?(DUMMY_RAW_TX)
  DUMMY_RAW_TX = ['01000000016ce7229f014164e254aad172b1f8b40d496942ad7e323b47e0424c2b2e2e3772010000006a47' \
                  '30440220463fcf8f57a61c4f8ede208773db8732bf3a0757d929a8cbbe29bf4905fe5ef6022005d74398fa' \
                  'f5b24912821836171af44f55f89858f3edf92863cde4823da11d4641210362f5fb9274834bb0cd0376a8d5' \
                  'd02bdbf459a37a62c5baef3fb06d1159b55597ffffffff01f0991600000000001976a9141f36a49fcf6ada' \
                  '1f74f82377b33b17b68f7a016188acd3740e00'].pack('H*').freeze
end

RSpec.shared_context 'engine setup' do
  subject(:engine) do
    described_class.new(
      store: store,
      utxo_pool: utxo_pool,
      broadcaster: broadcaster,
      network: :mainnet
    )
  end

  let(:store) { STORE_INSTANCE }
  let(:utxo_pool) { BSV::Wallet::Store::UTXOPool.new(store: store) }
  # Proof methods now live on Store directly. This alias keeps existing
  # spec setup/assertion code (proof_store.save_proof, etc.) working.
  let(:proof_store) { store }
  # Engine#initialize requires broadcaster post-#271. Specs that don't
  # exercise broadcasting inherit this stub; tests that drive inline
  # broadcast stub the relevant Broadcaster methods in their own +before+.
  let(:broadcaster) { instance_double(BSV::Network::Broadcaster) }

  let(:engine_with_privileged_keys) do
    priv_deriver = BSV::Wallet::KeyDeriver.new(private_key: root_key, privileged_key: privileged_key)
    described_class.new(
      store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
      key_deriver: priv_deriver, network: :mainnet
    )
  end
  let(:engine_with_keys) do
    described_class.new(
      store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
      key_deriver: key_deriver, network: :mainnet
    )
  end
  let(:verifier_hex) { verifier_key.public_key.to_hex }
  let(:verifier_key) { BSV::Primitives::PrivateKey.generate }
  let(:counterparty_hex) { counterparty_key.public_key.to_hex }
  let(:counterparty_key) { BSV::Primitives::PrivateKey.generate }
  let(:key_deriver) { BSV::Wallet::KeyDeriver.new(private_key: root_key) }
  let(:privileged_key) { BSV::Primitives::PrivateKey.generate }
  let(:root_key) { BSV::Primitives::PrivateKey.generate }

  # BRC-29 derivation lets. Strict-spec convention per HLR #460:
  # +protocol_id+ is the canonical +BSV::Wallet::BRC29::PROTOCOL_ID+
  # (aliasing +Auth::AuthFetch::PAYMENT_PROTOCOL_ID+ — +[2, '3241645161d8']+),
  # and +key_id+ is the prefix/suffix joined by a single ASCII space via
  # +BSV::Wallet::BRC29.key_id+. The atomic flip happened in #478.
  #
  # Prefix and suffix literals are base64url-only per
  # +BSV::Wallet::BRC29.key_id+'s validation contract (whitespace and
  # control bytes rejected). Human-readable strings like
  # +'wallet payment'+ from the pre-#460 fixtures are no longer valid
  # tokens — they'd raise +InvalidDerivationToken+ at the boundary.
  let(:derivation_prefix) { 'walletPayment' }
  let(:derivation_suffix) { 'suffix' }
  let(:brc29_protocol_id) { BSV::Wallet::BRC29::PROTOCOL_ID }
  let(:brc29_key_id) { BSV::Wallet::BRC29.key_id(derivation_prefix, derivation_suffix) }

  # BRC-29 key-derivation helpers. +brc29_derivation_params+ holds the
  # strict-spec composition once; private and public variants both splat it.
  def brc29_derivation_params(prefix:, suffix:, counterparty:)
    { protocol_id: BSV::Wallet::BRC29::PROTOCOL_ID,
      key_id: BSV::Wallet::BRC29.key_id(prefix, suffix),
      counterparty: counterparty }
  end

  def derive_brc29_private_key(prefix:, suffix:, counterparty:)
    key_deriver.derive_private_key(**brc29_derivation_params(prefix: prefix, suffix: suffix, counterparty: counterparty))
  end

  def derive_brc29_public_key(prefix:, suffix:, counterparty:)
    key_deriver.derive_public_key(**brc29_derivation_params(prefix: prefix, suffix: suffix, counterparty: counterparty))
  end

  around do |example|
    STORE_DB.transaction(rollback: :always, auto_savepoint: true) do
      example.run
    end
  end

  # Fund a reserve UTXO so outbound operations pass the limp mode guard.
  # Limp mode specs manage their own funding and skip this.
  before do |example|
    fund_reserve unless example.metadata[:skip_reserve]
  end

  # Parse Atomic BEEF and extract the subject transaction.
  def parse_beef_tx(beef_data)
    BSV::Transaction::Tx.from_beef(beef_data)
  end

  # Constants defined at top level (before shared_context) to avoid RSpec/LeakyConstantDeclaration.
  # Referenced as plain constants inside specs — they're in the global namespace.

  def op_true
    "\x51".b
  end

  def dummy_raw_tx
    ['01000000016ce7229f014164e254aad172b1f8b40d496942ad7e323b47e0424c2b2e2e3772010000006a47' \
     '30440220463fcf8f57a61c4f8ede208773db8732bf3a0757d929a8cbbe29bf4905fe5ef6022005d74398fa' \
     'f5b24912821836171af44f55f89858f3edf92863cde4823da11d4641210362f5fb9274834bb0cd0376a8d5' \
     'd02bdbf459a37a62c5baef3fb06d1159b55597ffffffff01f0991600000000001976a9141f36a49fcf6ada' \
     '1f74f82377b33b17b68f7a016188acd3740e00'].pack('H*')
  end

  def fund_wallet(satoshis: 1000, count: 1, basket: nil,
                  prefix: 'walletPayment', suffix: 'suffix',
                  sender_identity_key: 'self')
    # Pre-compute output specs so we can build a real source tx whose
    # outputs match the database promotion. Under strict
    # validate_for_handoff! (#296 Phase B), the wallet refuses to
    # construct outgoing BEEFs whose ancestry doesn't terminate at a
    # proven anchor; a synthetic source with a random wtxid would fail
    # at the next create_action.
    outputs = count.times.map do |i|
      out_suffix = count > 1 ? "#{suffix}#{i}" : suffix

      script = if key_deriver
                 derived_key = derive_brc29_private_key(
                   prefix: prefix, suffix: out_suffix,
                   counterparty: sender_identity_key || 'self'
                 )
                 pubkey_hash = BSV::Primitives::Digest.hash160(derived_key.public_key.compressed)
                 BSV::Script::Script.p2pkh_lock(pubkey_hash).to_binary
               else
                 op_true
               end

      {
        satoshis: satoshis, vout: i,
        locking_script: script,
        basket: basket,
        # HLR #467: every output spec states intent explicitly. Test
        # fixtures here build BRC-42 self-derived outputs — wallet-owned,
        # so always +'spendable'+.
        spendable_intent: 'spendable',
        derivation_prefix: prefix,
        derivation_suffix: out_suffix,
        sender_identity_key: sender_identity_key
      }
    end

    register_funded_outputs(outputs)
  end

  # Build a real Transaction::Tx whose outputs match the spec at the
  # given vouts. The single dummy input never gets walked at verify time
  # because the resulting tx is anchored with a merkle_path (proven
  # terminal short-circuits recursion).
  def build_funding_source_tx(output_specs)
    tx = BSV::Transaction::Tx.new
    tx.add_input(BSV::Transaction::TransactionInput.new(
                   prev_wtxid: ("\x00".b * 32), prev_tx_out_index: 0,
                   sequence: 0xffffffff, unlocking_script: BSV::Script::Script.new
                 ))
    output_specs.each do |spec|
      tx.add_output(BSV::Transaction::TransactionOutput.new(
                      satoshis: spec[:satoshis],
                      locking_script: BSV::Script::Script.from_binary(spec[:locking_script])
                    ))
    end
    tx
  end

  # Register the given output specs as spendable, backed by a realistic
  # source tx + anchored proof (so strict validate_for_handoff! sees the
  # closure). Used by tests that need to build their own funding
  # arrangements rather than the shared fund_wallet pattern.
  def register_funded_outputs(outputs, description: 'funding source')
    source_tx = build_funding_source_tx(outputs)
    source_wtxid = source_tx.wtxid
    source_raw_tx = source_tx.to_binary

    source_action = store.create_action(
      action: { description: description, broadcast_intent: :none }
    )
    store.sign_action(action_id: source_action[:id], wtxid: source_wtxid, raw_tx: source_raw_tx)

    # HLR #516 Sub 6.1 fix: +find_or_create_block+ now refuses to
    # attach two proofs with different roots to the same block row
    # (append-or-reject re-org guard). Fixtures used to jam every
    # funding source into height 1, which trips the guard now that
    # +save_proof+ passes the computed root to +find_or_create_block+.
    # Derive a unique block-height from the source_wtxid so each
    # fixture-generated tx has its own +blocks+ row — a realistic shape
    # anyway (real chain blocks each hold their own set of txs).
    fixture_height = source_wtxid.unpack1('N') & 0x7fffffff # 31-bit safe INTEGER
    merkle_path = BSV::Transaction::MerklePath.new(
      block_height: fixture_height,
      path: [[BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: source_wtxid, txid: true)]]
    )
    store.save_proof(
      wtxid: source_wtxid,
      proof: { raw_tx: source_raw_tx, merkle_path: merkle_path.to_binary, height: fixture_height }
    )

    store.promote_action(action_id: source_action[:id], outputs: outputs)
  end

  def fund_reserve
    fund_wallet(satoshis: 100_000, prefix: 'limpReserve', suffix: 'reserve', basket: 'reserve')
  end
end
