# frozen_string_literal: true

require_relative 'shared_context'

# Isolation specs for the fourth Engine decomposition extraction
# (HLR #357). BeefImporter is store-reading by design — these specs
# drive the real Store (same pattern as funding_strategy_spec and
# hydrator_spec) rather than faking +save_proof+ / +link_proof+ /
# +proof_exists?+, which would obscure the BEEF/proof wiring this
# class exists to do.
RSpec.describe BSV::Wallet::Engine::BeefImporter do
  include_context 'engine setup'

  # Mock chain tracker that accepts all merkle roots — mirrors
  # engine_spec.rb's #internalize_action setup.
  let(:chain_tracker) do
    tracker = double('ChainTracker')
    allow(tracker).to receive_messages(valid_root_for_height?: true, current_height: 900_000)
    tracker
  end

  # Real Hydrator over the shared Store — the one-way Hydrator
  # dependency is consumed for trustSelf hydration.
  let(:hydrator) { BSV::Wallet::Engine::Hydrator.new(store: store) }

  # Subject must come after include_context so this declaration wins —
  # mirrors hydrator_spec / funding_strategy_spec.
  subject(:beef_importer) do # rubocop:disable RSpec/LeadingSubject
    described_class.new(store: store, chain_tracker: chain_tracker, hydrator: hydrator)
  end

  # --- helpers ---------------------------------------------------------

  def build_merkle_path(tx, block_height: 800_000)
    sibling_hash = SecureRandom.random_bytes(32)
    BSV::Transaction::MerklePath.new(
      block_height: block_height,
      path: [[
        BSV::Transaction::MerklePath::PathElement.new(offset: 2, hash: tx.wtxid, txid: true),
        BSV::Transaction::MerklePath::PathElement.new(offset: 3, hash: sibling_hash)
      ]]
    )
  end

  # Build a verifiable BEEF: proven ancestor + subject spending it via
  # OP_1 scripts (trivially valid for SDK verify).
  def build_verifiable_beef(satoshis: 500, ancestor_satoshis: 600)
    ancestor = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
    ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                          satoshis: ancestor_satoshis,
                          locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                        ))
    ancestor.merkle_path = build_merkle_path(ancestor)

    subject_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
    subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                           prev_wtxid: ancestor.wtxid,
                           prev_tx_out_index: 0,
                           sequence: 0xFFFFFFFF,
                           unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                         ))
    subject_tx.inputs[0].source_transaction = ancestor
    subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                            satoshis: satoshis,
                            locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                          ))

    beef = BSV::Transaction::Beef.new
    beef.merge_transaction(ancestor)
    beef.merge_transaction(subject_tx)
    {
      beef_binary: beef.to_atomic_binary(subject_tx.wtxid),
      subject_tx: subject_tx,
      ancestor: ancestor
    }
  end

  # --- #parse_beef -----------------------------------------------------

  describe '#parse_beef' do
    it 'returns [beef, subject_tx] for a valid Atomic BEEF' do
      built = build_verifiable_beef
      beef, subject_tx = beef_importer.send(:parse_beef, built[:beef_binary])

      expect(beef).to be_a(BSV::Transaction::Beef)
      expect(subject_tx).to be_a(BSV::Transaction::Tx)
      expect(subject_tx.wtxid).to eq(built[:subject_tx].wtxid)
    end

    it 'raises InvalidBeefError for empty BEEF' do
      # Atomic BEEF prefix + V2 version + zero tx count
      empty = [0x01010101, 0x0200BEEF, 0].pack('NNC')
      expect { beef_importer.send(:parse_beef, empty) }
        .to raise_error(BSV::Wallet::InvalidBeefError)
    end

    it 'raises InvalidBeefError for malformed binary (ArgumentError wrap)' do
      expect { beef_importer.send(:parse_beef, "\x00".b) }
        .to raise_error(BSV::Wallet::InvalidBeefError)
    end
  end

  # --- #verify_incoming_transaction! ----------------------------------

  describe '#verify_incoming_transaction!' do
    it 'delegates to Transaction::Tx#verify with the injected chain_tracker' do
      built = build_verifiable_beef
      expect { beef_importer.send(:verify_incoming_transaction!, built[:subject_tx]) }
        .not_to raise_error
    end

    it 'raises InvalidBeefError when chain_tracker is nil' do
      importer = described_class.new(store: store, chain_tracker: nil, hydrator: hydrator)
      built = build_verifiable_beef
      expect { importer.send(:verify_incoming_transaction!, built[:subject_tx]) }
        .to raise_error(BSV::Wallet::InvalidBeefError, /chain_tracker required/)
    end

    it 'wraps VerificationError(:invalid_merkle_proof) as InvalidBeefError' do
      subject_tx = instance_double(BSV::Transaction::Tx)
      allow(subject_tx).to receive(:verify).and_raise(
        BSV::Transaction::VerificationError.new(:invalid_merkle_proof, 'bad proof')
      )
      expect { beef_importer.send(:verify_incoming_transaction!, subject_tx) }
        .to raise_error(BSV::Wallet::InvalidBeefError,
                        /SPV verification failed.*bad proof.*invalid_merkle_proof/)
    end

    it 'wraps VerificationError(:script_failure) as InvalidBeefError' do
      subject_tx = instance_double(BSV::Transaction::Tx)
      allow(subject_tx).to receive(:verify).and_raise(
        BSV::Transaction::VerificationError.new(:script_failure, 'script failed')
      )
      expect { beef_importer.send(:verify_incoming_transaction!, subject_tx) }
        .to raise_error(BSV::Wallet::InvalidBeefError,
                        /SPV verification failed.*script failed.*script_failure/)
    end

    it 'wraps VerificationError(:output_overflow) as InvalidBeefError' do
      subject_tx = instance_double(BSV::Transaction::Tx)
      allow(subject_tx).to receive(:verify).and_raise(
        BSV::Transaction::VerificationError.new(:output_overflow, 'outputs exceed inputs')
      )
      expect { beef_importer.send(:verify_incoming_transaction!, subject_tx) }
        .to raise_error(BSV::Wallet::InvalidBeefError,
                        /SPV verification failed.*outputs exceed inputs.*output_overflow/)
    end

    it 'wraps VerificationError(:missing_source) as InvalidBeefError' do
      subject_tx = instance_double(BSV::Transaction::Tx)
      allow(subject_tx).to receive(:verify).and_raise(
        BSV::Transaction::VerificationError.new(:missing_source, 'no source data')
      )
      expect { beef_importer.send(:verify_incoming_transaction!, subject_tx) }
        .to raise_error(BSV::Wallet::InvalidBeefError,
                        /SPV verification failed.*no source data.*missing_source/)
    end
  end

  # --- #hydrate_known_sources! ----------------------------------------

  describe '#hydrate_known_sources!' do
    it 'wires nil source_transactions from ProofStore via hydrator.wire_ancestor' do
      # Persist an ancestor proof so wire_ancestor can find it.
      ancestor = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                            satoshis: 1000,
                            locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                          ))
      mp = build_merkle_path(ancestor)
      store.save_proof(
        wtxid: ancestor.wtxid,
        proof: { raw_tx: ancestor.to_binary, height: 800_000, merkle_path: mp.to_binary }
      )

      # Subject with nil source_transaction — the trustSelf shape
      subject_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                             prev_wtxid: ancestor.wtxid,
                             prev_tx_out_index: 0,
                             sequence: 0xFFFFFFFF,
                             unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                           ))
      expect(subject_tx.inputs.first.source_transaction).to be_nil

      beef_importer.send(:hydrate_known_sources!, subject_tx)

      wired = subject_tx.inputs.first.source_transaction
      expect(wired).to be_a(BSV::Transaction::Tx)
      expect(wired.wtxid).to eq(ancestor.wtxid)
    end

    it 'leaves inputs whose source_transaction is already wired untouched' do
      built = build_verifiable_beef
      original_source = built[:subject_tx].inputs.first.source_transaction
      expect(original_source).not_to be_nil

      allow(hydrator).to receive(:wire_ancestor).and_call_original
      beef_importer.send(:hydrate_known_sources!, built[:subject_tx])
      expect(hydrator).not_to have_received(:wire_ancestor)
      expect(built[:subject_tx].inputs.first.source_transaction).to equal(original_source)
    end
  end

  # --- #save_beef_proofs ----------------------------------------------

  describe '#save_beef_proofs' do
    it 'persists every non-TxidOnly ancestor proof' do
      built = build_verifiable_beef
      beef = BSV::Transaction::Beef.from_binary(built[:beef_binary])

      action_result = store.create_action(
        action: { description: 'save_beef_proofs', broadcast_intent: :none }
      )
      store.sign_action(
        action_id: action_result[:id],
        wtxid: built[:subject_tx].wtxid,
        raw_tx: built[:subject_tx].to_binary
      )

      beef_importer.send(:save_beef_proofs, beef, built[:subject_tx].wtxid, action_result[:id])

      # Ancestor proof was persisted
      expect(store.find_proof(wtxid: built[:ancestor].wtxid)).not_to be_nil
    end

    it 'links the subject proof to the action only when the subject carries a merkle_path' do
      # Subject WITHOUT merkle_path — the #177 guard
      built = build_verifiable_beef
      beef = BSV::Transaction::Beef.from_binary(built[:beef_binary])

      action_result = store.create_action(
        action: { description: 'subject raw-tx-only', broadcast_intent: :none }
      )
      store.sign_action(
        action_id: action_result[:id],
        wtxid: built[:subject_tx].wtxid,
        raw_tx: built[:subject_tx].to_binary
      )

      allow(store).to receive(:link_proof).and_call_original
      beef_importer.send(:save_beef_proofs, beef, built[:subject_tx].wtxid, action_result[:id])
      expect(store).not_to have_received(:link_proof)
    end

    it 'links the subject proof to the action when the subject DOES carry a merkle_path' do
      # Build a BEEF whose subject has a merkle_path (with_proof shape).
      ancestor = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                            satoshis: 700,
                            locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                          ))
      ancestor.merkle_path = build_merkle_path(ancestor)

      subject_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                             prev_wtxid: ancestor.wtxid,
                             prev_tx_out_index: 0,
                             sequence: 0xFFFFFFFF,
                             unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                           ))
      subject_tx.inputs[0].source_transaction = ancestor
      subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                              satoshis: 600, locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                            ))
      subject_tx.merkle_path = build_merkle_path(subject_tx, block_height: 900_000)

      beef = BSV::Transaction::Beef.new
      beef.merge_transaction(ancestor)
      beef.merge_transaction(subject_tx)

      action_result = store.create_action(
        action: { description: 'proven subject', broadcast_intent: :none }
      )
      store.sign_action(action_id: action_result[:id], wtxid: subject_tx.wtxid, raw_tx: subject_tx.to_binary)

      allow(store).to receive(:link_proof).and_call_original
      beef_importer.send(:save_beef_proofs, beef, subject_tx.wtxid, action_result[:id])
      expect(store).to have_received(:link_proof)
        .with(hash_including(action_id: action_result[:id], tx_proof_id: kind_of(Integer)))
    end
  end

  # --- #replace_known_ancestors! --------------------------------------

  describe '#replace_known_ancestors!' do
    it 'trims an ancestor to TXID-only when its wtxid is in known_wtxids' do
      built = build_verifiable_beef
      beef = BSV::Transaction::Beef.from_binary(built[:beef_binary])

      beef_importer.send(:replace_known_ancestors!, beef, built[:subject_tx].wtxid, [built[:ancestor].wtxid])

      ancestor_entry = beef.transactions.find { |e| e.wtxid == built[:ancestor].wtxid }
      expect(ancestor_entry).to be_a(BSV::Transaction::Beef::TxidOnlyEntry)
    end

    it 'never trims the subject transaction' do
      built = build_verifiable_beef
      beef = BSV::Transaction::Beef.from_binary(built[:beef_binary])

      # Even when the subject's wtxid is in known_wtxids, leave it alone
      beef_importer.send(:replace_known_ancestors!, beef, built[:subject_tx].wtxid, [built[:subject_tx].wtxid])

      subject_entry = beef.transactions.find { |e| e.wtxid == built[:subject_tx].wtxid }
      expect(subject_entry).not_to be_a(BSV::Transaction::Beef::TxidOnlyEntry)
    end

    it 'trims an ancestor when its proof already exists in the store' do
      built = build_verifiable_beef
      beef = BSV::Transaction::Beef.from_binary(built[:beef_binary])
      mp = build_merkle_path(built[:ancestor])
      store.save_proof(
        wtxid: built[:ancestor].wtxid,
        proof: { raw_tx: built[:ancestor].to_binary, height: 800_000, merkle_path: mp.to_binary }
      )

      beef_importer.send(:replace_known_ancestors!, beef, built[:subject_tx].wtxid, nil)

      ancestor_entry = beef.transactions.find { |e| e.wtxid == built[:ancestor].wtxid }
      expect(ancestor_entry).to be_a(BSV::Transaction::Beef::TxidOnlyEntry)
    end
  end

  # --- #resolve_internalize_output ------------------------------------

  describe '#resolve_internalize_output' do
    it 'maps :wallet_payment to the payment_remittance derivation fields' do
      out = {
        satoshis: 500, output_index: 1, protocol: :wallet_payment,
        payment_remittance: {
          derivation_prefix: 'pfx', derivation_suffix: 'sfx',
          sender_identity_key: 'sender_hex'
        }
      }
      spec = beef_importer.send(:resolve_internalize_output, out)

      expect(spec).to include(
        satoshis: 500, vout: 1,
        derivation_prefix: 'pfx', derivation_suffix: 'sfx',
        sender_identity_key: 'sender_hex'
      )
    end

    it 'maps :basket_insertion to the insertion_remittance fields' do
      out = {
        satoshis: 700, output_index: 2, protocol: :basket_insertion,
        insertion_remittance: {
          basket: 'gift', custom_instructions: 'ci', tags: ['a'],
          derivation_prefix: 'pfx', derivation_suffix: 'sfx',
          sender_identity_key: 'sender_hex'
        }
      }
      spec = beef_importer.send(:resolve_internalize_output, out)

      expect(spec).to include(
        basket: 'gift', custom_instructions: 'ci', tags: ['a'],
        derivation_prefix: 'pfx', sender_identity_key: 'sender_hex'
      )
      expect(spec).not_to include(:output_type)
    end

    it 'marks basket_insertion without derivation_prefix as output_type root' do
      out = {
        satoshis: 700, output_index: 0, protocol: :basket_insertion,
        insertion_remittance: { basket: 'gift' }
      }
      spec = beef_importer.send(:resolve_internalize_output, out)

      expect(spec[:output_type]).to eq('root')
    end
  end

  # --- #import end-to-end ---------------------------------------------

  describe '#import' do
    it 'returns { accepted: true } and persists the incoming action + spendable output' do
      built = build_verifiable_beef(satoshis: 500)

      result = beef_importer.import(
        tx: built[:beef_binary],
        description: 'beef_importer smoke',
        labels: ['incoming'],
        outputs: [{
          output_index: 0, protocol: :basket_insertion, satoshis: 500,
          insertion_remittance: {
            basket: 'smoke', derivation_prefix: 'test',
            derivation_suffix: '1', sender_identity_key: 'self'
          }
        }]
      )

      expect(result).to eq({ accepted: true })

      action = store.find_action(wtxid: built[:subject_tx].wtxid)
      expect(action).not_to be_nil
      expect(action[:broadcast_intent]).to eq('none')
      expect(action[:outgoing]).to be(false)

      # Subject proof persisted via save_proof + the ancestor proof too
      expect(store.find_proof(wtxid: built[:subject_tx].wtxid)).not_to be_nil
      expect(store.find_proof(wtxid: built[:ancestor].wtxid)).not_to be_nil
    end

    it 'raises InvalidParameterError when an output names a non-existent vout' do
      built = build_verifiable_beef
      expect do
        beef_importer.import(
          tx: built[:beef_binary],
          description: 'vout out of range',
          outputs: [{ output_index: 99, protocol: :basket_insertion, satoshis: 500 }]
        )
      end.to raise_error(BSV::Wallet::InvalidParameterError, /output_index/)
    end

    it 'raises InvalidParameterError for non-Array outputs (#362 shape guard)' do
      built = build_verifiable_beef
      expect do
        beef_importer.import(tx: built[:beef_binary], description: 'bad outputs', outputs: nil)
      end.to raise_error(BSV::Wallet::InvalidParameterError, /outputs/)
    end

    it 'persists nothing when output resolution fails — no dangling internal action (#362)' do
      built = build_verifiable_beef(satoshis: 500)
      expect do
        beef_importer.import(
          tx: built[:beef_binary], description: 'dangling guard',
          outputs: [{ output_index: 99, protocol: :basket_insertion, satoshis: 500 }]
        )
      end.to raise_error(BSV::Wallet::InvalidParameterError)

      # Validation runs before any write, so the action was never created.
      expect(store.find_action(wtxid: built[:subject_tx].wtxid)).to be_nil
      expect(store.find_proof(wtxid: built[:subject_tx].wtxid)).to be_nil
    end

    it 'rolls back the created+signed action if promotion fails mid-ingress (#362 atomicity)' do
      built = build_verifiable_beef(satoshis: 500)
      allow(store).to receive(:promote_action).and_raise(StandardError, 'promote boom')

      expect do
        beef_importer.import(
          tx: built[:beef_binary], description: 'rollback',
          outputs: [{
            output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: { basket: 'x' }
          }]
        )
      end.to raise_error(/promote boom/)

      # Without the enclosing transaction this would be a signed, unpromoted,
      # never-cleaned-up dangling action. The wrapper rolls it all back.
      expect(store.find_action(wtxid: built[:subject_tx].wtxid)).to be_nil
      expect(store.find_proof(wtxid: built[:subject_tx].wtxid)).to be_nil
    end

    it 'raises InvalidParameterError when declared satoshis mismatch the transaction output' do
      built = build_verifiable_beef(satoshis: 500)
      expect do
        beef_importer.import(
          tx: built[:beef_binary],
          description: 'satoshis mismatch',
          outputs: [{
            output_index: 0, protocol: :basket_insertion, satoshis: 999,
            insertion_remittance: { basket: 'gift' }
          }]
        )
      end.to raise_error(BSV::Wallet::InvalidParameterError, /satoshis/)
    end

    it 'persists ancestor proofs before trimming known ancestors (the ordering hinge)' do
      # The hinge: +replace_known_ancestors!+ only trims an ancestor when
      # +proof_exists?(wtxid: ancestor)+ is true (or the wtxid is in
      # +known_txids+). With no explicit +known_txids+, the trim
      # observing +proof_exists? == true+ for the ancestor is *only*
      # possible if +save_beef_proofs+ has already persisted the proof.
      # We assert this by spying +proof_exists?+ on the store and
      # checking that the proof was already saved at the moment of the
      # +proof_exists?+ call (which only +replace_known_ancestors!+
      # makes).
      built = build_verifiable_beef
      ancestor_wtxid = built[:ancestor].wtxid

      proof_existed_at_trim_check = nil
      allow(store).to receive(:proof_exists?).and_wrap_original do |orig, **kwargs|
        # Snapshot the persisted state at the moment of the trim's
        # existence check on the ancestor.
        proof_existed_at_trim_check = orig.call(wtxid: ancestor_wtxid) if kwargs[:wtxid] == ancestor_wtxid
        orig.call(**kwargs)
      end

      beef_importer.import(
        tx: built[:beef_binary],
        description: 'ordering check',
        trust_self: 'known',
        outputs: [{
          output_index: 0, protocol: :basket_insertion, satoshis: 500,
          insertion_remittance: { basket: 'smoke' }
        }]
      )

      expect(store).to have_received(:proof_exists?).with(wtxid: ancestor_wtxid)
      expect(proof_existed_at_trim_check).to be(true)
    end
  end

  # --- TXID-only + verify integration ---------------------------------

  describe 'TXID-only + verify integration' do
    # The highest-risk assumption in the chain tracker pivot:
    # +make_txid_only+ mutates the BEEF's @transactions list but does
    # NOT invalidate the in-memory +source_transaction+ pointers wired
    # by +Beef.from_binary+. +Transaction::Tx#verify+ walks via
    # +input.source_transaction+, not the BEEF list, so verification
    # must succeed after TXID-only conversion. This used to live on
    # +action_spec.rb+; migrated here with the ingress helpers.
    it 'verify succeeds after replace_known_ancestors! converts ancestors to TXID-only' do
      ancestor = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                            satoshis: 1000,
                            locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                          ))
      ancestor.merkle_path = build_merkle_path(ancestor)

      subject_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                             prev_wtxid: ancestor.wtxid,
                             prev_tx_out_index: 0,
                             sequence: 0xFFFFFFFF,
                             unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                           ))
      subject_tx.inputs[0].source_transaction = ancestor
      subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                              satoshis: 900,
                              locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                            ))

      beef = BSV::Transaction::Beef.new
      beef.merge_transaction(ancestor)
      beef.merge_transaction(subject_tx)
      beef_data = beef.to_atomic_binary(subject_tx.wtxid)

      # Step 1: parse BEEF — wires source_transaction pointers
      parsed_beef, parsed_subject = beef_importer.send(:parse_beef, beef_data)
      expect(parsed_subject.inputs[0].source_transaction).not_to be_nil
      expect(parsed_subject.inputs[0].source_transaction.merkle_path).not_to be_nil

      # Step 2: pre-populate ProofStore so the ancestor is "known",
      # then trim
      store.save_proof(
        wtxid: ancestor.wtxid,
        proof: { raw_tx: ancestor.to_binary, merkle_path: ancestor.merkle_path.to_binary, height: 800_000 }
      )
      beef_importer.send(:replace_known_ancestors!, parsed_beef, parsed_subject.wtxid, nil)

      replaced = parsed_beef.transactions.find { |bt| bt.wtxid == ancestor.wtxid }
      expect(replaced).to be_a(BSV::Transaction::Beef::TxidOnlyEntry)

      # The in-memory source_transaction pointer survives the BEEF
      # list mutation — the load-bearing invariant.
      expect(parsed_subject.inputs[0].source_transaction).not_to be_nil
      expect(parsed_subject.inputs[0].source_transaction.merkle_path).not_to be_nil

      # Step 3: verify still succeeds.
      expect(parsed_subject.verify(chain_tracker: chain_tracker)).to be true
    end
  end
end
