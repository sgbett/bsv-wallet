# frozen_string_literal: true

require_relative 'shared_context'

# Isolation specs for the third Engine decomposition extraction
# (HLR #343). Hydrator is store-reading by design — these specs drive
# the real Store (same pattern as funding_strategy_spec) rather than
# faking +find_proof+ / +resolve_inputs_for_signing+, which would
# obscure the BEEF/proof wiring this class exists to do.
RSpec.describe BSV::Wallet::Engine::Hydrator do
  include_context 'engine setup'

  # The engine shared context defines +subject(:engine)+ which would
  # resolve to +Hydrator.new+ here (described_class). Override so the
  # subject is a real Hydrator over the shared Store. Subject declared
  # after include_context so this declaration wins — mirrors
  # action_spec's pattern.
  subject(:hydrator) { described_class.new(store: store) } # rubocop:disable RSpec/LeadingSubject

  # --- helpers (migrated from the wire_ancestor block on action_spec) ---

  def make_fake_tx(satoshis:, inputs: [])
    tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
    inputs.each do |inp|
      tx.add_input(BSV::Transaction::TransactionInput.new(
                     prev_wtxid: inp[:prev_wtxid],
                     prev_tx_out_index: 0,
                     unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                   ))
    end
    tx.add_output(BSV::Transaction::TransactionOutput.new(
                    satoshis: satoshis,
                    locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                  ))
    tx
  end

  def make_merkle_path(wtxid:, height: 800_000)
    sibling_hash = SecureRandom.random_bytes(32)
    BSV::Transaction::MerklePath.new(
      block_height: height,
      path: [[
        BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid, txid: true),
        BSV::Transaction::MerklePath::PathElement.new(offset: 1, hash: sibling_hash)
      ]]
    )
  end

  describe '#wire_ancestor' do
    it 'returns a proven ancestor with merkle_path set (no recursion)' do
      fake_tx = make_fake_tx(satoshis: 1000)
      raw_tx = fake_tx.to_binary
      wtxid = fake_tx.wtxid
      mp = make_merkle_path(wtxid: wtxid)

      store.save_proof(
        wtxid: wtxid,
        proof: { height: 800_000, merkle_path: mp.to_binary, raw_tx: raw_tx }
      )

      result = hydrator.wire_ancestor(wtxid)
      expect(result).to be_a(BSV::Transaction::Tx)
      expect(result.merkle_path).to be_a(BSV::Transaction::MerklePath)
      expect(result.merkle_path.block_height).to eq(800_000)
    end

    it 'recursively wires source_transactions for unconfirmed ancestors' do
      # Grandparent: proven (has merkle_path)
      grandparent_tx = make_fake_tx(satoshis: 2000)
      gp_raw = grandparent_tx.to_binary
      gp_wtxid = grandparent_tx.wtxid
      gp_mp = make_merkle_path(wtxid: gp_wtxid, height: 799_000)

      store.save_proof(
        wtxid: gp_wtxid,
        proof: { height: 799_000, merkle_path: gp_mp.to_binary, raw_tx: gp_raw }
      )

      # Parent: unconfirmed (no merkle_path), spends grandparent
      parent_tx = make_fake_tx(satoshis: 1500, inputs: [{ prev_wtxid: gp_wtxid }])
      parent_raw = parent_tx.to_binary
      parent_wtxid = parent_tx.wtxid

      store.save_proof(wtxid: parent_wtxid, proof: { raw_tx: parent_raw })

      result = hydrator.wire_ancestor(parent_wtxid)
      expect(result).to be_a(BSV::Transaction::Tx)
      expect(result.merkle_path).to be_nil

      # The input's source_transaction should be wired to the grandparent
      expect(result.inputs.first.source_transaction).to be_a(BSV::Transaction::Tx)
      expect(result.inputs.first.source_transaction.merkle_path).to be_a(BSV::Transaction::MerklePath)
      expect(result.inputs.first.source_transaction.merkle_path.block_height).to eq(799_000)
    end

    it 'terminates on circular references via visited set' do
      # Real Bitcoin transactions can't form cycles (wtxid depends on content),
      # but ProofStore entries can. Use fixed wtxids and store transactions
      # whose inputs reference each other's key.
      wtxid_a = ("\x01" * 32).b
      wtxid_b = ("\x02" * 32).b

      tx_a = make_fake_tx(satoshis: 500, inputs: [{ prev_wtxid: wtxid_b }])
      tx_b = make_fake_tx(satoshis: 500, inputs: [{ prev_wtxid: wtxid_a }])

      store.save_proof(wtxid: wtxid_a, proof: { raw_tx: tx_a.to_binary })
      store.save_proof(wtxid: wtxid_b, proof: { raw_tx: tx_b.to_binary })

      # Walk from wtxid_a → loads tx_a → input references wtxid_b →
      # loads tx_b → input references wtxid_a → ALREADY VISITED → stops.
      result = hydrator.wire_ancestor(wtxid_a)
      expect(result).to be_a(BSV::Transaction::Tx)
    end

    it 'returns nil for missing proofs' do
      missing_wtxid = SecureRandom.random_bytes(32)
      expect(hydrator.wire_ancestor(missing_wtxid)).to be_nil
    end

    it 'returns nil for proofs whose raw_tx is too short to deserialise' do
      # The schema's raw_tx_min_length CHECK rejects proofs < 10 bytes
      # at the public store API, so this branch is defensive belt-and-
      # braces — exercise it through a store double rather than try to
      # write an invalid row.
      short_wtxid = SecureRandom.random_bytes(32)
      short_store = instance_double(BSV::Wallet::Store)
      allow(short_store).to receive(:find_proof)
        .with(wtxid: short_wtxid)
        .and_return({ raw_tx: 'short'.b })

      expect(described_class.new(store: short_store).wire_ancestor(short_wtxid)).to be_nil
    end
  end

  describe '#build_atomic_beef' do
    # Build a minimal but realistic egress scenario: a proven source
    # action's output, an empty outbound action, and an input row
    # linking the two so +resolve_inputs_for_signing+ has data to
    # return. The subject tx spends that one input.
    it 'wires the subject inputs source_transactions from resolved sources and assembles Atomic BEEF' do
      # Proven source tx: simple OP_TRUE output for 5000 sats
      source_tx = make_fake_tx(satoshis: 5000)
      source_raw = source_tx.to_binary
      source_wtxid = source_tx.wtxid
      source_mp = make_merkle_path(wtxid: source_wtxid)
      store.save_proof(
        wtxid: source_wtxid,
        proof: { height: 800_000, merkle_path: source_mp.to_binary, raw_tx: source_raw }
      )

      # Funding action (the action that produced source_tx): write a row
      # so the inputs/outputs JOIN can find it. Persist its wtxid and an
      # output row at vout 0.
      source_action = store.create_action(
        action: { description: 'source', broadcast_intent: :none }
      )
      store.sign_action(action_id: source_action[:id], wtxid: source_wtxid, raw_tx: source_raw)
      source_output_ids = store.promote_action(
        action_id: source_action[:id],
        outputs: [{
          satoshis: 5000, vout: 0, locking_script: OP_TRUE.b,
          output_type: 'outbound'
        }]
      )

      # Subject action: lock the source output as input.
      subject_action = store.create_action(
        action: { description: 'subject', broadcast_intent: :none }
      )
      store.lock_inputs(
        action_id: subject_action[:id],
        inputs: [{ output_id: source_output_ids.first, vin: 0 }]
      )

      # Subject tx: spends the source output (prev_wtxid = source_wtxid).
      subject_tx = make_fake_tx(satoshis: 4500, inputs: [{ prev_wtxid: source_wtxid }])
      subject_raw = subject_tx.to_binary

      beef_binary = hydrator.build_atomic_beef(subject_raw, subject_action[:id])
      expect(beef_binary).to be_a(String)
      expect(beef_binary.encoding).to eq(Encoding::ASCII_8BIT)

      # Round-trip: the BEEF should contain both the source (proven) and
      # the subject; the subject's first input source_transaction must be
      # the wired source tx carrying its merkle_path.
      beef = BSV::Transaction::Beef.from_binary(beef_binary)
      subject_entry = beef.transactions.find { |e| e.wtxid == subject_tx.wtxid }
      expect(subject_entry).not_to be_nil
      expect(subject_entry.transaction).to be_a(BSV::Transaction::Tx)
      wired_source = subject_entry.transaction.inputs.first.source_transaction
      expect(wired_source).to be_a(BSV::Transaction::Tx)
      expect(wired_source.merkle_path).to be_a(BSV::Transaction::MerklePath)
    end

    it 'raises EgressBeefInvalidError on a count-parity mismatch' do
      # A subject with no wired ancestry assembles to a 1-tx BEEF. Force the
      # walked-ancestry count to diverge to prove the guard fires — the
      # mismatch is otherwise a true invariant that cannot occur in practice.
      action = store.create_action(action: { description: 'parity', broadcast_intent: :none })
      subject_tx = make_fake_tx(satoshis: 1000)
      # Separate instance (not the subject) so the stub does not trip
      # RSpec/SubjectStub.
      tested = described_class.new(store: store)
      allow(tested).to receive(:count_wired_transactions).and_return(99)

      expect { tested.build_atomic_beef(subject_tx.to_binary, action[:id]) }
        .to raise_error(BSV::Wallet::EgressBeefInvalidError, /count parity/)
    end
  end

  describe '#validate_for_handoff!' do
    # Build a BEEF whose subject input's source_transaction terminates at
    # a merkle-proven leaf — a structurally complete graph. The
    # TrustedSelfChainTracker accepts the merkle_path's root unchallenged.
    def build_complete_beef
      source_tx = make_fake_tx(satoshis: 5000)
      source_tx.merkle_path = make_merkle_path(wtxid: source_tx.wtxid)

      subject_tx = make_fake_tx(satoshis: 4500, inputs: [{ prev_wtxid: source_tx.wtxid }])
      subject_tx.inputs.first.source_transaction = source_tx

      beef = BSV::Transaction::Beef.new
      beef.merge_transaction(subject_tx)
      [beef.to_atomic_binary(subject_tx.wtxid), subject_tx.wtxid]
    end

    it 'returns without raising for a complete proven graph' do
      atomic_beef, subject_wtxid = build_complete_beef
      expect { hydrator.validate_for_handoff!(atomic_beef, subject_wtxid) }.not_to raise_error
    end

    it 'raises EgressBeefInvalidError when the subject wtxid is absent from the BEEF' do
      atomic_beef, = build_complete_beef
      missing_wtxid = SecureRandom.random_bytes(32)

      expect { hydrator.validate_for_handoff!(atomic_beef, missing_wtxid) }
        .to raise_error(BSV::Wallet::EgressBeefInvalidError, /missing from constructed BEEF/)
    end

    it 'raises EgressBeefInvalidError when an ancestor lacks merkle_path (verify fails)' do
      # Unconfirmed source (no merkle_path) — verify cannot close the
      # proof chain so TrustedSelfChainTracker yields a VerificationError
      # which the validator wraps as EgressBeefInvalidError.
      source_tx = make_fake_tx(satoshis: 5000)
      subject_tx = make_fake_tx(satoshis: 4500, inputs: [{ prev_wtxid: source_tx.wtxid }])
      subject_tx.inputs.first.source_transaction = source_tx

      beef = BSV::Transaction::Beef.new
      beef.merge_transaction(subject_tx)
      atomic_beef = beef.to_atomic_binary(subject_tx.wtxid)

      expect { hydrator.validate_for_handoff!(atomic_beef, subject_tx.wtxid) }
        .to raise_error(BSV::Wallet::EgressBeefInvalidError,
                        /wallet refuses to ship structurally invalid BEEF/)
    end
  end
end
