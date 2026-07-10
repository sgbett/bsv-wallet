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
  #
  # The +output_script+ kwarg controls the subject's output locking script:
  #
  #   * +:op_true+  (default) — +\x51+ stub. Use when callers pass a
  #     derivation triple to +basket_insertion+ / +wallet_payment+ (the
  #     +spendable_recoverable+ CHECK accepts non-root + controls).
  #   * +:root_p2pkh+ — the suite-pinned root P2PKH literal
  #     (+TEST_ROOT_LOCKING_SCRIPT+). Use for tests that import without
  #     a derivation triple (basket_insertion with no remittance), so
  #     the no-controls + 'spendable' permutation lands on a structurally
  #     valid root output (HLR #467).
  def build_verifiable_beef(satoshis: 500, ancestor_satoshis: 600, output_script: :op_true)
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
    chosen_script = output_script == :root_p2pkh ? TEST_ROOT_LOCKING_SCRIPT : OP_TRUE
    subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                            satoshis: satoshis,
                            locking_script: BSV::Script::Script.from_binary(chosen_script)
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

  # --- #assert_proofs_complete! ---------------------------------------

  describe '#assert_proofs_complete! (#296 Phase C ingress invariant)' do
    # Persist the BEEF's proofs the way #import does, then exercise the
    # post-condition directly. Setup mirrors #save_beef_proofs's specs.
    def persist_beef_proofs(built)
      beef = BSV::Transaction::Beef.from_binary(built[:beef_binary])
      action_result = store.create_action(
        action: { description: 'assert_proofs_complete', broadcast_intent: :none }
      )
      store.sign_action(
        action_id: action_result[:id],
        wtxid: built[:subject_tx].wtxid,
        raw_tx: built[:subject_tx].to_binary
      )
      store.save_proof(wtxid: built[:subject_tx].wtxid, proof: { raw_tx: built[:subject_tx].to_binary })
      beef_importer.send(:save_beef_proofs, beef, built[:subject_tx].wtxid, action_result[:id])
      beef
    end

    it 'passes once save_beef_proofs has persisted every non-TxidOnly entry' do
      built = build_verifiable_beef
      beef = persist_beef_proofs(built)

      expect { beef_importer.send(:assert_proofs_complete!, beef) }.not_to raise_error
    end

    it 'raises InvalidBeefError when an entry was not persisted' do
      built = build_verifiable_beef
      beef = persist_beef_proofs(built)

      # Simulate save_beef_proofs having silently dropped the ancestor.
      allow(store).to receive(:find_proof).and_wrap_original do |orig, wtxid:|
        wtxid == built[:ancestor].wtxid ? nil : orig.call(wtxid: wtxid)
      end

      expect { beef_importer.send(:assert_proofs_complete!, beef) }
        .to raise_error(BSV::Wallet::InvalidBeefError, /not persisted/)
    end

    it 'raises InvalidBeefError when a merkle-bearing entry lost its merkle_path' do
      built = build_verifiable_beef # ancestor carries a merkle_path
      beef = persist_beef_proofs(built)

      allow(store).to receive(:find_proof).and_wrap_original do |orig, wtxid:|
        res = orig.call(wtxid: wtxid)
        res && wtxid == built[:ancestor].wtxid ? res.merge(merkle_path: nil) : res
      end

      expect { beef_importer.send(:assert_proofs_complete!, beef) }
        .to raise_error(BSV::Wallet::InvalidBeefError, /carried a merkle_path/)
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
      # HLR #467: spendable_intent is stated explicitly — every
      # internalize output is wallet-bound by definition (that's the
      # point of +internalizeAction+).
      expect(spec[:spendable_intent]).to eq('spendable')
      expect(spec).not_to include(:output_type)
    end

    # HLR #467: basket_insertion without derivation_prefix is still
    # +spendable_intent: 'spendable'+ — the locking script will match
    # the wallet's per-instance root P2PKH literal (enforced declaratively
    # by +outputs.spendable_recoverable+, not by an inference here).
    it 'marks basket_insertion without derivation_prefix as spendable_intent: spendable' do
      out = {
        satoshis: 700, output_index: 0, protocol: :basket_insertion,
        insertion_remittance: { basket: 'gift' }
      }
      spec = beef_importer.send(:resolve_internalize_output, out)

      expect(spec[:spendable_intent]).to eq('spendable')
      expect(spec).not_to include(:output_type)
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

    # HLR #516 Sub 2 — successful ingress marks the exact wtxid set that
    # +Tx#verify+ walked as +verified_via = 'spv'+ in +tx_proofs+. The
    # walked set comes from the SDK's own +verified:+ accumulator (bsv-sdk
    # 0.26+); the wallet does not re-implement the walk. Non-atomic BEEF
    # sibling entries the SDK never visits stay uncached by construction.
    describe 'verification cache write (HLR #516 Sub 2)' do
      def import_ok(built)
        beef_importer.import(
          tx: built[:beef_binary], description: 'sub-2 cache write',
          outputs: [{
            output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: {
              basket: 'sub two cache', derivation_prefix: 'test',
              derivation_suffix: '1', sender_identity_key: 'self'
            }
          }]
        )
      end

      def verified_via(wtxid)
        store.verification_state(wtxid: wtxid)&.[](:verified_via)
      end

      it 'marks subject + walked ancestors as spv on success' do
        built = build_verifiable_beef(satoshis: 500)
        import_ok(built)

        expect(verified_via(built[:subject_tx].wtxid)).to eq('spv')
        expect(verified_via(built[:ancestor].wtxid)).to eq('spv')
      end

      it 'writes the wtxids at the current VERIFIER_VERSION' do
        built = build_verifiable_beef(satoshis: 500)
        import_ok(built)

        state = store.verification_state(wtxid: built[:subject_tx].wtxid)
        expect(state[:verifier_version]).to eq(BSV::Wallet::VERIFIER_VERSION)
        expect(state[:verified_at]).to be_a(Time)
      end

      it 'issues a single mark_verified_batch(via: spv) call, not N per ancestor' do
        built = build_verifiable_beef(satoshis: 500)
        allow(store).to receive(:mark_verified_batch).and_call_original

        import_ok(built)

        # Sub 2's contract: subject + all walked ancestors marked in one
        # set-based UPDATE — one +via: 'spv'+ call regardless of ancestor
        # count. HLR #521's +via: 'self_built'+ site (Sub 3) dispatches
        # +mark_verified+ singular for the subject, which delegates to
        # +mark_verified_batch+ internally; that call is filtered out
        # here so this spec keeps its Sub 2 focus.
        expect(store).to have_received(:mark_verified_batch)
          .with(hash_including(via: BSV::Wallet::Store::Models::TxProof::VERIFIED_VIA_SPV))
          .once
      end

      it 'rolls back cache writes when promotion fails mid-ingress (atomicity)' do
        built = build_verifiable_beef(satoshis: 500)
        allow(store).to receive(:promote_action).and_raise(StandardError, 'promote boom')

        expect { import_ok(built) }.to raise_error(/promote boom/)

        # Cache writes joined the same db.transaction — the failure rolls
        # them back alongside the proof + action rows. No partial trust.
        expect(store.verification_state(wtxid: built[:subject_tx].wtxid)).to be_nil
        expect(store.verification_state(wtxid: built[:ancestor].wtxid)).to be_nil
      end

      it 'does not write when verify_incoming_transaction! raises (before-write guard)' do
        built = build_verifiable_beef(satoshis: 500)
        # Reject the ancestor's merkle path — Tx#verify raises
        # +:invalid_merkle_proof+, which +verify_incoming_transaction!+
        # wraps into +InvalidBeefError+. Write path never reached.
        allow(chain_tracker).to receive(:valid_root_for_height?).and_return(false)

        expect { import_ok(built) }.to raise_error(BSV::Wallet::InvalidBeefError)

        expect(store.verification_state(wtxid: built[:subject_tx].wtxid)).to be_nil
        expect(store.verification_state(wtxid: built[:ancestor].wtxid)).to be_nil
      end

      # REGRESSION: a 3-hop chain must mark every walked wtxid, not just
      # the subject and its direct parent. +Tx#verify+ recurses via
      # +input.source_transaction+ until it hits a merkle-proven ancestor;
      # a proven grandparent behind an unproven parent must appear in
      # +verified_wtxids+ and get marked +'spv'+. Belt-and-braces against
      # any future SDK change that silently narrowed the walk.
      it 'marks every walked wtxid in a multi-hop chain (subject → parent → grandparent)' do
        # Grandparent: merkle-proven root of the chain. Verify will
        # short-circuit here (merkle_path present, chain_tracker accepts).
        grandparent = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
        grandparent.add_output(BSV::Transaction::TransactionOutput.new(
                                 satoshis: 700,
                                 locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                               ))
        grandparent.merkle_path = build_merkle_path(grandparent)

        # Parent: unproven, spends grandparent. Verify runs script here
        # and recurses into grandparent.
        parent = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
        parent.add_input(BSV::Transaction::TransactionInput.new(
                           prev_wtxid: grandparent.wtxid,
                           prev_tx_out_index: 0,
                           sequence: 0xFFFFFFFF,
                           unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                         ))
        parent.inputs[0].source_transaction = grandparent
        parent.add_output(BSV::Transaction::TransactionOutput.new(
                            satoshis: 600,
                            locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                          ))

        # Subject: unproven, spends parent. Verify starts here, walks
        # parent → grandparent, marks all three.
        subject_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
        subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                               prev_wtxid: parent.wtxid,
                               prev_tx_out_index: 0,
                               sequence: 0xFFFFFFFF,
                               unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                             ))
        subject_tx.inputs[0].source_transaction = parent
        subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                                satoshis: 500,
                                locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                              ))

        beef = BSV::Transaction::Beef.new
        beef.merge_transaction(grandparent)
        beef.merge_transaction(parent)
        beef.merge_transaction(subject_tx)

        beef_importer.import(
          tx: beef.to_atomic_binary(subject_tx.wtxid),
          description: 'multi-hop chain mark',
          outputs: [{
            output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: {
              basket: 'multi hop chain', derivation_prefix: 'test',
              derivation_suffix: '1', sender_identity_key: 'self'
            }
          }]
        )

        # All three hops marked — the SDK walk visits each one.
        expect(verified_via(subject_tx.wtxid)).to eq('spv')
        expect(verified_via(parent.wtxid)).to eq('spv')
        expect(verified_via(grandparent.wtxid)).to eq('spv')
      end

      # REGRESSION: non-atomic BEEF (BRC-62) with an unrelated sibling entry
      # not reachable from the subject via +input.source_transaction+.
      # +save_beef_proofs+ persists proof rows for every non-TXID-only entry
      # in +beef.transactions+ — including the sibling — but only the wtxid
      # set +Tx#verify+ actually walked (subject + reachable ancestors) may
      # be marked +verified_via = 'spv'+. A future change that broadened
      # the marked set (e.g. handing +beef.transactions.map(&:wtxid)+
      # instead of +verified_wtxids.keys+ to +mark_verified_batch+) would
      # accidentally trust the sibling — persistent trust escalation for
      # any tx the BEEF's producer chose to include.
      it 'does not mark unrelated siblings in a non-atomic BEEF as spv' do
        # Main chain: proven ancestor spent by subject.
        ancestor = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
        ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                              satoshis: 600,
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
                                satoshis: 500,
                                locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                              ))

        # Sibling: independent proven tx, no relationship to subject.
        # Its bytes get persisted via +save_beef_proofs+ but +Tx#verify+
        # never visits it (not reachable from subject_tx).
        sibling = BSV::Transaction::Tx.new(version: 1, lock_time: 42)
        sibling.add_output(BSV::Transaction::TransactionOutput.new(
                             satoshis: 999,
                             locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                           ))
        # +block_height: 800_000 + 1+ — a different block from the main
        # chain's fixture (helper default is 800_000); the delta is
        # incidental, not a load-bearing property of the test.
        sibling.merkle_path = build_merkle_path(sibling, block_height: 800_000 + 1)

        beef = BSV::Transaction::Beef.new
        beef.merge_transaction(ancestor)
        beef.merge_transaction(sibling)
        beef.merge_transaction(subject_tx) # last → subject on the non-atomic parse path

        # Non-atomic BRC-62 binary (no atomic wrapper). +parse_beef+ picks
        # +beef.transactions.last+ as the subject when +subject_wtxid+ is
        # absent — see +BeefImporter#parse_beef+.
        beef_binary = beef.to_binary

        beef_importer.import(
          tx: beef_binary,
          description: 'non-atomic sibling guard',
          outputs: [{
            output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: {
              basket: 'sibling guard', derivation_prefix: 'test',
              derivation_suffix: '1', sender_identity_key: 'self'
            }
          }]
        )

        # Subject + walked ancestor: marked spv.
        expect(verified_via(subject_tx.wtxid)).to eq('spv')
        expect(verified_via(ancestor.wtxid)).to eq('spv')

        # Sibling: proof row persisted (save_beef_proofs saw it), but
        # verification stamp absent (Tx#verify never reached it).
        expect(store.find_proof(wtxid: sibling.wtxid)).not_to be_nil
        expect(store.verification_state(wtxid: sibling.wtxid)).to be_nil
      end
    end

    # HLR #521 Sub 3 — the ingress atomic block records a +self_built+
    # lifecycle annotation on the subject BEFORE Sub 2's +'spv'+ mark
    # runs in the same +db.transaction+. Because +Store#mark_verified+'s
    # monotonic predicate is on +verifier_version+ only (not on
    # +verified_via+ strength), writing +self_built+ AFTER the SPV mark
    # would silently downgrade. This ordering pins the invariant: the
    # +self_built+ call is dispatched, and the FINAL committed row
    # carries +'spv'+ (SPV wins).
    describe 'HLR #521 self_built annotation ordering' do
      def import_ok(built)
        beef_importer.import(
          tx: built[:beef_binary], description: 'sub-3 self_built',
          outputs: [{
            output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: {
              basket: 'sub three self built', derivation_prefix: 'test',
              derivation_suffix: '1', sender_identity_key: 'self'
            }
          }]
        )
      end

      it 'dispatches mark_verified(via: self_built) for the subject during ingress' do
        built = build_verifiable_beef(satoshis: 500)
        allow(store).to receive(:mark_verified).and_call_original

        import_ok(built)

        expect(store).to have_received(:mark_verified).with(
          wtxid: built[:subject_tx].wtxid,
          via: BSV::Wallet::Store::Models::TxProof::VERIFIED_VIA_SELF_BUILT
        )
      end

      it 'commits verified_via = spv (SPV mark upgrades self_built in the same transaction)' do
        built = build_verifiable_beef(satoshis: 500)
        import_ok(built)

        # self_built was stamped mid-transaction, then upgraded to spv by
        # Sub 2's mark_verified_batch. The committed row reflects spv.
        state = store.verification_state(wtxid: built[:subject_tx].wtxid)
        expect(state[:verified_via]).to eq('spv')
      end

      it 'rolls back the self_built stamp when promotion fails mid-ingress' do
        built = build_verifiable_beef(satoshis: 500)
        allow(store).to receive(:promote_action).and_raise(StandardError, 'promote boom')

        expect { import_ok(built) }.to raise_error(/promote boom/)

        # The self_built write joined the same db.transaction — a
        # downstream failure rolls it back alongside proof + action rows.
        expect(store.verification_state(wtxid: built[:subject_tx].wtxid)).to be_nil
      end
    end

    # #533 code-review — +CompetingBlockHeaderError+ from
    # +find_or_create_block+ is translated to +InvalidBeefError+ at
    # the ingress boundary so +Interface::BeefImporter#import+'s
    # documented error contract stays honest. Every ingress failure
    # surfaces as +InvalidBeefError+; consumers don't need to know
    # about the new error type.
    it 'translates CompetingBlockHeaderError from an ancestor into InvalidBeefError' do
      built = build_verifiable_beef(satoshis: 500)
      allow(store).to receive(:save_proof).and_raise(
        BSV::Wallet::CompetingBlockHeaderError.new(800_000)
      )

      expect do
        beef_importer.import(
          tx: built[:beef_binary], description: 'competing header',
          outputs: [{
            output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: { basket: 'x' }
          }]
        )
      end.to raise_error(BSV::Wallet::InvalidBeefError, /competing_header/)
    end

    # #533 code-review — Hydrator is an in-memory cache with no
    # rollback hook. Prior to the post-commit flush, an ingress that
    # raised mid-transaction would have already told the Hydrator
    # "wtxid X's proof arrived", even though the tx_proofs write got
    # rolled back. Next BEEF walk would then wire_ancestor to a ghost
    # anchor. Assertion: on rollback, the Hydrator saw zero
    # proof_arrived calls for the subject wtxid.
    it 'does not poison the Hydrator cache on mid-ingress rollback' do
      built = build_verifiable_beef(satoshis: 500)
      allow(store).to receive(:promote_action).and_raise(StandardError, 'promote boom')
      allow(hydrator).to receive(:proof_arrived).and_call_original

      expect do
        beef_importer.import(
          tx: built[:beef_binary], description: 'hydrator rollback',
          outputs: [{
            output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: { basket: 'x' }
          }]
        )
      end.to raise_error(/promote boom/)

      expect(hydrator).not_to have_received(:proof_arrived)
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

    it 'rolls the whole ingress back when proof closure is incomplete (#296 Phase C)' do
      # Make save_proof a no-op for the ancestor so its proof never lands.
      # The post-condition catches the gap and rolls back the subject too.
      built = build_verifiable_beef(satoshis: 500)
      allow(store).to receive(:save_proof).and_wrap_original do |orig, wtxid:, proof:|
        next 0 if wtxid == built[:ancestor].wtxid

        orig.call(wtxid: wtxid, proof: proof)
      end

      expect do
        beef_importer.import(
          tx: built[:beef_binary], description: 'proof-closure rollback',
          outputs: [{
            output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: { basket: 'x' }
          }]
        )
      end.to raise_error(BSV::Wallet::InvalidBeefError, /not persisted/)

      expect(store.find_action(wtxid: built[:subject_tx].wtxid)).to be_nil
      expect(store.find_proof(wtxid: built[:subject_tx].wtxid)).to be_nil
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
      # The basket_insertion below carries no derivation triple, so the
      # importer's 'root'-shim sets spendable_intent='spendable' and the
      # subject's locking_script must be the wallet's root P2PKH (HLR #467).
      built = build_verifiable_beef(output_script: :root_p2pkh)
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
