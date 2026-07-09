# frozen_string_literal: true

require_relative 'shared_context'

# Engine::Action class-level smoke specs (#284).
#
# Exhaustive behavioural coverage stays in engine_spec.rb — those tests
# exercise the public Engine surface, which delegates here. This file
# proves the class methods are callable in their own right (the round-trip
# through Engine is exercised by every existing create_action spec).
RSpec.describe BSV::Wallet::Engine::Action do
  include_context 'engine setup'

  # The shared context's +subject(:engine)+ uses +described_class.new+, which
  # resolves to +Engine::Action.new+ here. Override so +engine+ in this file
  # is a real +Engine+, matching how the production code calls Action.
  # Subject must come after include_context so this declaration wins.
  subject(:engine) do # rubocop:disable RSpec/LeadingSubject
    BSV::Wallet::Engine.new(
      store: store, utxo_pool: utxo_pool, broadcaster: broadcaster, network: :mainnet
    )
  end

  let(:engine_with_keys) do
    BSV::Wallet::Engine.new(
      store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
      key_deriver: key_deriver, network: :mainnet
    )
  end

  # #369 — Action commits to one canonical shape for its `row:` argument (a
  # Store#action_to_hash hash) and fails fast at construction on anything else.
  describe '#initialize row: guard' do
    it 'accepts the canonical action_to_hash hash' do
      expect { described_class.new(engine: engine, row: { id: 1 }) }.not_to raise_error
    end

    it 'rejects a non-Hash row' do
      expect { described_class.new(engine: engine, row: Object.new) }
        .to raise_error(ArgumentError, /action_to_hash hash with a non-nil :id/)
    end

    it 'rejects a Hash missing :id' do
      expect { described_class.new(engine: engine, row: { wtxid: nil }) }
        .to raise_error(ArgumentError, /non-nil :id/)
    end

    it 'rejects a Hash with a nil :id (the removed { id: nil } stub shape)' do
      expect { described_class.new(engine: engine, row: { id: nil }) }
        .to raise_error(ArgumentError, /non-nil :id/)
    end
  end

  describe '.create' do
    # +.create+ slimmed to a row-creation helper in #402 Stage 2 commit 5.
    # The orchestrator role (input acquisition, build, persist, dispatch)
    # moved up to +Engine#build_action+; +.create+ now just inserts the
    # empty +actions+ row and returns an instance. End-to-end orchestration
    # coverage lives at +engine_spec.rb+ ("#create_action") + integration.
    it 'inserts an empty actions row and returns an Action wrapping it' do
      result = described_class.create(
        engine: engine, description: 'row helper smoke', intent: :delayed
      )

      expect(result).to be_a(described_class)
      expect(result.id).to be_a(Integer)
      expect(result.row[:description]).to eq('row helper smoke')
      expect(result.row[:broadcast_intent]).to eq('delayed')
    end

    it 'attaches labels when provided' do
      result = described_class.create(
        engine: engine, description: 'with labels', intent: :delayed,
        labels: %w[smoke unit]
      )
      labels = store.query_actions(labels: %w[smoke], include_labels: true)[:actions]
      expect(labels.first[:labels]).to include('smoke', 'unit')
      expect(labels.first[:id]).to eq(result.id)
    end
  end

  describe '.build_input_specs' do
    it 'returns [] for nil inputs' do
      expect(described_class.build_input_specs(nil)).to eq([])
    end

    it 'maps caller inputs onto Store input specs with default vin numbering' do
      specs = described_class.build_input_specs([
                                                  { output_id: 7 },
                                                  { output_id: 9, vin: 5, sequence_number: 0xABCD, input_description: 'ok' }
                                                ])
      expect(specs).to eq([
                            { output_id: 7, vin: 0, nsequence: nil, description: nil },
                            { output_id: 9, vin: 5, nsequence: 0xABCD, description: 'ok' }
                          ])
    end
  end

  describe '.build_output_specs' do
    # HLR #467: explicit +spendable_intent+ is required on every output;
    # inferring from derivation presence is gone (cf.
    # +docs/reference/intent-and-outcomes.md+).
    it "passes a caller's spendable_intent: 'none' through unchanged" do
      specs = described_class.build_output_specs([
                                                   { satoshis: 100, locking_script: OP_TRUE,
                                                     spendable_intent: 'none' }
                                                 ])
      expect(specs.first).to include(satoshis: 100, vout: 0, spendable_intent: 'none')
    end

    it "passes a caller's spendable_intent: 'spendable' (BRC-42 self) through unchanged" do
      specs = described_class.build_output_specs([
                                                   { satoshis: 100, locking_script: OP_TRUE,
                                                     spendable_intent: 'spendable',
                                                     derivation_prefix: 'p', derivation_suffix: 's' }
                                                 ])
      expect(specs.first).to include(spendable_intent: 'spendable',
                                     derivation_prefix: 'p', derivation_suffix: 's')
    end

    it 'raises InvalidParameterError when spendable_intent is missing' do
      expect do
        described_class.build_output_specs([
                                             { satoshis: 100, locking_script: OP_TRUE }
                                           ])
      end.to raise_error(BSV::Wallet::InvalidParameterError, /spendable_intent.*HLR #467/m)
    end

    it 'honours an explicit vout mapping' do
      specs = described_class.build_output_specs(
        [
          { satoshis: 100, locking_script: OP_TRUE, spendable_intent: 'none' },
          { satoshis: 200, locking_script: OP_TRUE, spendable_intent: 'none' }
        ],
        { 0 => 3, 1 => 2 }
      )
      expect(specs.map { |s| s[:vout] }).to eq([3, 2])
    end

    # --- Engine-surface 8-permutation matrix (HLR #467) ---
    #
    # Third driver in the triad (DB CHECK -> constraints_spec.rb;
    # model validate -> models/output_spec.rb; engine surface -> here).
    # +build_output_specs+ is intentionally narrow: it requires
    # +:spendable_intent+ and passes everything else through verbatim, so
    # the engine surface doesn't see the matrix as four-valid-four-invalid
    # directly. The contract is the pass-through: each cell's
    # +spendable_intent+ + +derivation_*+ shape arrives on the emitted
    # spec exactly as written. The downstream model/DB layers (covered by
    # the sibling matrices) then accept or reject. Co-locating the matrix
    # here proves that the engine surface threads every permutation through
    # without mutation — the inversion in HLR #467 (intent stated, never
    # inferred) holds for all eight permutations symmetrically.
    describe '8-permutation pass-through' do
      # [label, controls_present, intent]
      # We omit root_pattern from this driver — the engine surface doesn't
      # inspect the locking script. The matrix's 8 cells collapse to 4 here
      # (controls x intent), each exercised against an arbitrary script.
      matrix = [
        ['no_controls + spendable', false, 'spendable'],
        ['no_controls + none',      false, 'none'],
        ['controls + spendable',    true,  'spendable'],
        ['controls + none',         true,  'none']
      ]

      matrix.each do |label, controls, intent|
        it "passes [#{label}] through to the emitted spec verbatim" do
          out = { satoshis: 100, locking_script: OP_TRUE, spendable_intent: intent }
          if controls
            out[:derivation_prefix] = 'p'
            out[:derivation_suffix] = 's'
            out[:sender_identity_key] = 'self'
          end

          specs = described_class.build_output_specs([out])

          expect(specs.first).to include(spendable_intent: intent)
          if controls
            expect(specs.first).to include(derivation_prefix: 'p',
                                           derivation_suffix: 's',
                                           sender_identity_key: 'self')
          else
            expect(specs.first[:derivation_prefix]).to be_nil
            expect(specs.first[:derivation_suffix]).to be_nil
            expect(specs.first[:sender_identity_key]).to be_nil
          end
        end
      end
    end
  end

  describe '#apply_caller_spends!' do
    # Action#sign! split in #402 Stage 2 commit 5: the row-level signing
    # step is +#apply_caller_spends!+ (deserialise unsigned tx, apply
    # caller scripts, sign remaining inputs, persist signed raw_tx +
    # proof). BEEF assembly + dispatch moved up to +Engine#sign_action+.
    it 'returns the signed wtxid + raw_tx for a deferred action' do
      create_result = engine.brc100.create_action(
        description: 'action apply_caller_spends! smoke',
        inputs: [], sign_and_process: false,
        outputs: [
          # 0 satoshis: exercises the deferred-sign lifecycle without
          # creating value-from-nothing (#296 Phase B).
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
            sender_identity_key: 'self' }
        ]
      )
      reference = create_result[:signable_transaction][:reference]
      action = described_class.find(engine: engine, reference: reference)

      result = action.apply_caller_spends!(spends: {})

      expect(result).to include(:wtxid, :raw_tx)
      expect(result[:wtxid].bytesize).to eq(32)
      expect(result[:raw_tx]).to be_a(String)
    end

    # HLR #521 — deferred sign completion is one of three egress-side
    # sites that stamp +verified_via = 'self_built'+ after the signer runs.
    # Trust claim: wallet's signer produced the P2PKH witness bytes for
    # wallet-owned inputs; +self_built+ names lifecycle-provenance only.
    it 'populates the verification cache as self_built' do
      create_result = engine.brc100.create_action(
        description: 'apply_caller_spends! self_built',
        inputs: [], sign_and_process: false,
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
            sender_identity_key: 'self' }
        ]
      )
      reference = create_result[:signable_transaction][:reference]
      action = described_class.find(engine: engine, reference: reference)

      result = action.apply_caller_spends!(spends: {})

      state = store.verification_state(wtxid: result[:wtxid])
      expect(state[:verified_via])
        .to eq(BSV::Wallet::Store::Models::TxProof::VERIFIED_VIA_SELF_BUILT)
      expect(state[:verifier_version]).to eq(BSV::Wallet::VERIFIER_VERSION)
    end
  end

  # HLR #521 — the three egress-side +self_built+ writes exercised
  # through the engine surface (send, internal, deferred sign — that
  # last one lives in the +#apply_caller_spends!+ block above).
  #
  # +self_built+ is lifecycle metadata; Sub 5 excludes it from the
  # short-circuit trust set. These specs only assert the write happens
  # and the constant is used — trust-decision behaviour is Sub 5's
  # coverage.
  describe 'HLR #521 egress self_built writes' do
    it 'send-path (no_send: false) populates cache as self_built' do
      fund_wallet(satoshis: 1_000_000, count: 1, prefix: 'sendSelfBuilt',
                  suffix: 'root')
      recipient = BSV::Primitives::PrivateKey.generate.public_key.to_hex

      result = engine_with_keys.send_payment(
        recipient: recipient, satoshis: 5_000
      )

      state = store.verification_state(wtxid: result[:wtxid])
      expect(state[:verified_via])
        .to eq(BSV::Wallet::Store::Models::TxProof::VERIFIED_VIA_SELF_BUILT)
    end

    it 'internal-action path (no_send: true) populates cache as self_built' do
      fund_wallet(satoshis: 1_000_000, count: 1, prefix: 'internalSelfBuilt',
                  suffix: 'root')

      result = engine_with_keys.brc100.create_action(
        description: 'internal self_built',
        outputs: [{ satoshis: 5_000, locking_script: SecureRandom.random_bytes(25),
                    spendable: false }],
        no_send: true
      )
      wtxid = result[:txid]

      state = store.verification_state(wtxid: wtxid)
      expect(state[:verified_via])
        .to eq(BSV::Wallet::Store::Models::TxProof::VERIFIED_VIA_SELF_BUILT)
    end
  end

  describe 'Engine#sign_action no_send guard' do
    it 'rejects no_send when the underlying action was not created with broadcast_intent: none' do
      # Deferred path defaults to broadcast_intent: :delayed — no_send: true
      # at sign time is a runtime override the base wallet does not support.
      create_result = engine.brc100.create_action(
        description: 'no_send guard',
        inputs: [], sign_and_process: false,
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
            sender_identity_key: 'self' }
        ]
      )
      reference = create_result[:signable_transaction][:reference]

      expect { engine.brc100.sign_action(spends: {}, reference: reference, no_send: true) }
        .to raise_error(BSV::Wallet::UnsupportedActionError, /signAction\(no_send: true\)/)
    end
  end

  describe '#abort!' do
    it 'aborts an unsigned action when invoked directly on an Action instance' do
      create_result = engine.brc100.create_action(
        description: 'action abort! smoke',
        inputs: [],
        sign_and_process: false,
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            output_description: 'output', spendable: false }
        ]
      )
      reference = create_result[:signable_transaction][:reference]
      row = store.find_action(reference: reference)

      result = described_class.new(engine: engine, row: row).abort!

      expect(result).to eq({ aborted: true })
      expect(store.find_action(reference: reference)).to be_nil
    end

    it 'is the entry point Engine#abort_action delegates to' do
      create_result = engine.brc100.create_action(
        description: 'abort delegator',
        inputs: [],
        sign_and_process: false,
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            output_description: 'output', spendable: false }
        ]
      )
      reference = create_result[:signable_transaction][:reference]

      expect(engine.brc100.abort_action(reference: reference)).to eq({ aborted: true })
      expect(store.find_action(reference: reference)).to be_nil
    end
  end

  describe 'internalize (via Engine#internalize_action)' do
    # +Action.internalize+ is gone — incoming-BEEF ingestion now lives
    # on +Engine::BeefImporter+ (HLR #357). This smoke covers the
    # public Engine surface that delegates to it; isolation specs
    # exist in +beef_importer_spec.rb+.
    let(:chain_tracker_mock) do
      tracker = double('ChainTracker')
      allow(tracker).to receive_messages(valid_root_for_height?: true, current_height: 900_000)
      tracker
    end

    let(:engine_with_tracker) do
      BSV::Wallet::Engine.new(
        store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
        chain_tracker: chain_tracker_mock, network: :mainnet
      )
    end

    def build_internalize_beef(satoshis: 500)
      ancestor = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                            satoshis: satoshis + 100,
                            locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                          ))
      sibling = SecureRandom.random_bytes(32)
      ancestor.merkle_path = BSV::Transaction::MerklePath.new(
        block_height: 800_000,
        path: [[
          BSV::Transaction::MerklePath::PathElement.new(offset: 2, hash: ancestor.wtxid, txid: true),
          BSV::Transaction::MerklePath::PathElement.new(offset: 3, hash: sibling)
        ]]
      )

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
      [beef.to_atomic_binary(subject_tx.wtxid), subject_tx]
    end

    it 'returns BRC-100 { accepted: true } and persists the incoming action' do
      beef_data, subject_tx = build_internalize_beef(satoshis: 500)

      result = engine_with_tracker.brc100.internalize_action(
        tx: beef_data,
        description: 'action internalize smoke',
        labels: ['incoming'],
        outputs: [
          {
            output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: {
              basket: 'smoke', derivation_prefix: 'test',
              derivation_suffix: '1', sender_identity_key: 'self'
            }
          }
        ]
      )

      expect(result).to eq({ accepted: true })

      # Output landed in the basket
      listed = engine_with_tracker.brc100.list_outputs(basket: 'smoke')
      expect(listed[:total_outputs]).to eq(1)

      # Action row was persisted with the subject tx's wtxid
      action = store.find_action(wtxid: subject_tx.wtxid)
      expect(action).not_to be_nil
      expect(action[:broadcast_intent]).to eq('none')
      expect(action[:outgoing]).to be(false)
    end

    it 'delegates to Engine::BeefImporter (the ingress collaborator)' do
      beef_data, = build_internalize_beef(satoshis: 700)

      result = engine_with_tracker.brc100.internalize_action(
        tx: beef_data,
        description: 'internalize delegator smoke',
        outputs: [
          {
            output_index: 0, protocol: :basket_insertion, satoshis: 700,
            insertion_remittance: {
              basket: 'delegator', derivation_prefix: 'test',
              derivation_suffix: '1', sender_identity_key: 'self'
            }
          }
        ]
      )

      expect(result).to eq({ accepted: true })
      expect(engine_with_tracker.beef_importer).to be_a(BSV::Wallet::Engine::BeefImporter)
    end
  end

  describe '.list' do
    it 'returns the wallet-vocab { total:, actions: } hash shape' do
      # BRC100 re-keys +:total+ → +:total_actions+ at the wrap layer
      # (#402 PR 2 normalisation — all collection primitives now use
      # +:total+ on the Engine side with the domain key for the rows:
      # +{ total:, actions: }+ here, +{ total:, outputs: }+ for
      # +list_outputs+, +{ total:, certificates: }+ for
      # +list_certificates+ + +discover_by_*+).
      store.create_action(action: { description: 'list smoke other', broadcast_intent: :none })
      action = store.create_action(action: { description: 'list smoke target', broadcast_intent: :none })
      described_class.attach_labels(engine: engine, action_id: action[:id], labels: ['list-smoke'])

      result = described_class.list(engine: engine, labels: ['list-smoke'])

      expect(result).to include(:total, :actions)
      expect(result[:total]).to eq(1)
      expect(result[:actions].first[:description]).to eq('list smoke target')
    end

    it 'is the entry point Engine#list_actions delegates to' do
      action = store.create_action(action: { description: 'list delegator smoke', broadcast_intent: :none })
      described_class.attach_labels(engine: engine, action_id: action[:id], labels: ['list-delegator'])

      expect(engine.brc100.list_actions(labels: ['list-delegator'])).to include(total_actions: 1)
    end
  end

  describe '.find' do
    it 'returns an Action when a row exists for the reference' do
      row = store.create_action(action: { description: 'findable smoke', broadcast_intent: :none })

      found = described_class.find(engine: engine, reference: row[:reference])

      expect(found).to be_a(described_class)
      expect(found.id).to eq(row[:id])
    end

    it 'returns nil when no row exists for the reference' do
      expect(described_class.find(engine: engine, reference: SecureRandom.uuid)).to be_nil
    end
  end

  describe '.find_by_id' do
    it 'returns an Action when a row exists for the id' do
      row = store.create_action(action: { description: 'findable by id smoke', broadcast_intent: :none })

      found = described_class.find_by_id(engine: engine, id: row[:id])

      expect(found).to be_a(described_class)
      expect(found.id).to eq(row[:id])
    end

    it 'returns nil when no row exists for the id' do
      expect(described_class.find_by_id(engine: engine, id: 999_999_999)).to be_nil
    end
  end

  describe '.attach_labels' do
    it 'is a no-op for nil labels' do
      action = store.create_action(action: { description: 'no labels', broadcast_intent: :none })
      expect do
        described_class.attach_labels(engine: engine, action_id: action[:id], labels: nil)
      end.not_to(change { store.query_actions(labels: ['anything'])[:total] })
    end

    it 'creates labels and links them to the action' do
      action = store.create_action(action: { description: 'with labels', broadcast_intent: :none })
      described_class.attach_labels(engine: engine, action_id: action[:id], labels: %w[smoke unit])

      result = store.query_actions(labels: ['smoke'], label_query_mode: :any, include_labels: true)
      expect(result[:actions].first[:labels]).to include('smoke')
    end
  end

  # wire_ancestor specs migrated to engine/hydrator_spec.rb in #345 along
  # with the method itself. The +verify_incoming_transaction!+ /
  # TXID-only-survival blocks that used to live here moved to
  # +beef_importer_spec.rb+ in #357 along with the ingress helpers.
end
