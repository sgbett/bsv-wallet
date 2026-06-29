# frozen_string_literal: true

require_relative 'shared_context'
require_relative '../../network/synthetic_chain'

# End-to-end proof that the opt-in +:spv_headers+ trust model (HLR #335)
# verifies an incoming BEEF against a *locally-validated* header chain
# rather than a trusted chain-query Service, and fails closed when the
# proof is not covered by — or is inconsistent with — that validated
# chain.
#
# == What "end-to-end" means here
#
# The real ingress seam is exercised: an incoming Atomic BEEF flows
# through +Engine::BeefImporter+ →
# +#verify_incoming_transaction!+ → +Transaction::Tx#verify(chain_tracker:)+,
# with a *real* {BSV::Network::SpvHeaderChainTracker} over a *real* Store
# (the +:store+ context). Only the network edge is stubbed: +services.call+
# returns synthetic regtest headers per height, so the chain the tracker
# validates (PoW + linkage from the injected checkpoint) is deterministic
# and offline. Nothing about the merkle-root decision is faked — the
# tracker reads the header it persisted and compares bytes.
#
# == The consistent-BEEF construction
#
# The subject transaction carries its merkle path directly, so
# +Transaction::Tx#verify+ takes the proven-leaf short-circuit and the
# whole assertion is about the merkle proof (no ancestor scripts to wire).
# The leaf sits at *offset 2*, not offset 0 — deliberately, so the SDK's
# coinbase-maturity rule (an offset-0 leaf must be ≥ 100 blocks below the
# tip) never fires and the proof's validity turns purely on the header
# chain. We then mine the synthetic header at the proof's height +H+ so
# its +merkle_root+ equals +MerklePath#compute_root+ for that leaf — the
# header *commits* to the BEEF. The chain is extended +100 above +H+ as
# well, both to seat a realistic validated tip and to match the tracker's
# maturity over-sync. The trust anchor is a synthetic checkpoint injected
# via the +checkpoint:+ kwarg (the +config.spv_checkpoint+ seam), so the
# spec never depends on the real mainnet anchor.
#
# == Fail-closed cases
#
#   * Tampered: the header at +H+ commits to a *different* root, so the
#     computed root mismatches and verification is rejected.
#   * Below the checkpoint: a proof at a height beneath the anchor has no
#     validated header to check against, so it is rejected.
#
# == Default mode unchanged
#
# The same consistent BEEF, verified under the default +ChainTracker+
# (trusted-service), still passes — proving the +:spv_headers+ path is
# additive and the default behaviour is untouched.
#
# SQLite by default (must also pass there); Postgres QA-verified.
RSpec.describe 'spv_headers BEEF verification (HLR #335)', :store do # rubocop:disable RSpec/DescribeClass
  # The synthetic chain's trust anchor. An arbitrary height that mirrors
  # the real mainnet checkpoint's magnitude without depending on it.
  let(:checkpoint_height) { 955_000 }
  # The proof's block height — 10 above the anchor, so it is comfortably
  # covered yet close enough to keep the synthetic chain small.
  let(:proof_height) { checkpoint_height + 10 }

  # A real Hydrator over the shared Store — the BeefImporter's one-way
  # dependency. Never exercised here (no trustSelf), but required by the
  # constructor, mirroring +beef_importer_spec+.
  let(:hydrator) { BSV::Wallet::Engine::Hydrator.new(store: store) }

  # Stubbed network edge: answer +:get_block_header+ from the supplied
  # synthetic chain, 404-shaped (fail-closed) for any height the chain
  # does not supply. +:current_height+ (the trusted-service tracker's tip
  # query) returns the synthetic tip. Mirrors
  # +spv_header_chain_tracker_spec+'s service double.
  def stub_services(chain)
    services = instance_double(BSV::Network::Services)
    allow(services).to receive(:call) do |command, height = nil|
      case command
      when :get_block_header
        chain.key?(height) ? SyntheticChain.success_response(chain[height]) : SyntheticChain.error_response
      when :current_height
        BSV::Network::ProtocolResponse.new(nil, data: chain.keys.max, http_success: true)
      else
        raise "unexpected command #{command}"
      end
    end
    services
  end

  # A subject transaction carrying a single-level, offset-2 merkle path
  # (proven leaf; non-coinbase so no maturity gate). The output uses the
  # suite's root P2PKH literal so a no-derivation +basket_insertion+ import
  # lands a structurally valid root output (HLR #467).
  #
  # @return [BSV::Transaction::Tx]
  def build_proven_subject(height:, satoshis: 500)
    subject = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
    subject.add_output(BSV::Transaction::TransactionOutput.new(
                         satoshis: satoshis,
                         locking_script: BSV::Script::Script.from_binary(TEST_ROOT_LOCKING_SCRIPT)
                       ))
    sibling = SecureRandom.random_bytes(32)
    subject.merkle_path = BSV::Transaction::MerklePath.new(
      block_height: height,
      path: [[
        BSV::Transaction::MerklePath::PathElement.new(offset: 2, hash: subject.wtxid, txid: true),
        BSV::Transaction::MerklePath::PathElement.new(offset: 3, hash: sibling)
      ]]
    )
    subject
  end

  # The Atomic BEEF (BRC-95) carrying +subject+ as the subject transaction.
  def atomic_beef_for(subject)
    beef = BSV::Transaction::Beef.new
    beef.merge_transaction(subject)
    beef.to_atomic_binary(subject.wtxid)
  end

  # Build the synthetic header chain from the checkpoint up to
  # +proof_height + 100+, with the header at +proof_height+ mined so its
  # +merkle_root+ equals +committed_root+ (wire-order 32 bytes). When
  # +committed_root+ is the subject's +compute_root+, the chain *commits*
  # to the BEEF; pass a different value to model tampering.
  #
  # @return [Hash{Integer => BSV::Network::BlockHeader}]
  def chain_committing_to(committed_root)
    below = SyntheticChain.build(start_height: checkpoint_height, count: proof_height - checkpoint_height)
    chain = below.dup
    chain[proof_height] = SyntheticChain.mine(
      prev_wire: below[proof_height - 1].block_hash,
      merkle_wire: committed_root,
      time: 1_700_000_500
    )
    # Extend 100 above the proof: seats a realistic validated tip and
    # matches the tracker's coinbase-maturity over-sync.
    prev = chain[proof_height].block_hash
    (1..100).each do |i|
      height = proof_height + i
      merkle = "merkle-root-h#{height}".b.ljust(32, "\x00".b)[0, 32]
      header = SyntheticChain.mine(prev_wire: prev, merkle_wire: merkle, time: 1_700_000_500 + i)
      chain[height] = header
      prev = header.block_hash
    end
    chain
  end

  # An SpvHeaderChainTracker anchored at the synthetic checkpoint, driven
  # by +chain+ through the stubbed services. This is the real tracker —
  # the only stub is the network edge beneath it.
  def spv_tracker_for(chain)
    BSV::Network::SpvHeaderChainTracker.new(
      store: store,
      services: stub_services(chain),
      checkpoint: SyntheticChain.checkpoint_for(chain, checkpoint_height)
    )
  end

  # A BeefImporter wired with the given tracker over the shared Store —
  # the same construction +cli.rb+ performs once it has selected a tracker
  # from +config.trust_model+.
  def importer_with(tracker)
    BSV::Wallet::Engine::BeefImporter.new(store: store, chain_tracker: tracker, hydrator: hydrator)
  end

  # The no-derivation basket_insertion output spec for a root-pattern UTXO
  # (HLR #467): no derivation triple ⇒ root-key ownership, which the
  # subject's root P2PKH locking script satisfies.
  def root_internalize_outputs
    [{ output_index: 0, protocol: :basket_insertion, satoshis: 500,
       insertion_remittance: { basket: 'smoke' } }]
  end

  # ------------------------------------------------------------------
  # The SPV verification step itself (verify_incoming_transaction!), the
  # exact seam BeefImporter#import drives. Asserting here isolates the
  # header-chain decision from the downstream HLR #467 output-shape rules.
  # ------------------------------------------------------------------
  describe 'verify_incoming_transaction! through the validated header chain' do
    it 'passes for a proof the validated header chain covers and commits to' do
      subject = build_proven_subject(height: proof_height)
      tracker = spv_tracker_for(chain_committing_to(subject.merkle_path.compute_root))
      importer = importer_with(tracker)

      expect { importer.send(:verify_incoming_transaction!, subject) }.not_to raise_error
    end

    it 'fails closed when the validated header commits to a DIFFERENT root (tampered)' do
      subject = build_proven_subject(height: proof_height)
      tampered_root = SecureRandom.random_bytes(32)
      tracker = spv_tracker_for(chain_committing_to(tampered_root))
      importer = importer_with(tracker)

      expect { importer.send(:verify_incoming_transaction!, subject) }
        .to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*invalid_merkle_proof/)
    end

    it 'fails closed for a proof below the checkpoint (no validated header to check against)' do
      below = build_proven_subject(height: checkpoint_height - 5)
      # The chain is irrelevant — the height is beneath the anchor, so the
      # tracker rejects before any sync.
      tracker = spv_tracker_for(chain_committing_to(below.merkle_path.compute_root))
      importer = importer_with(tracker)

      expect { importer.send(:verify_incoming_transaction!, below) }
        .to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*invalid_merkle_proof/)
    end

    it 'records a locally-validated chain (the proof is believed because every link was verified)' do
      subject = build_proven_subject(height: proof_height)
      tracker = spv_tracker_for(chain_committing_to(subject.merkle_path.compute_root))

      importer_with(tracker).send(:verify_incoming_transaction!, subject)

      # The tip advanced past the proof under PoW+linkage validation — not
      # a single trusted-service answer, but a verified chain from the
      # anchor. (Bare proof of the "validated, not trusted" distinction.)
      expect(store.validated_tip(from_height: checkpoint_height)).to be >= proof_height
      expect(store.header_at(height: proof_height)).not_to be_nil
    end
  end

  # ------------------------------------------------------------------
  # The full ingress: an incoming Atomic BEEF flowing through #import end
  # to end, accepting the consistent case and rolling back the tampered
  # one (principle of state — no half-imported action).
  # ------------------------------------------------------------------
  describe '#import end-to-end under :spv_headers' do
    it 'accepts a consistent BEEF and persists the incoming action + subject proof' do
      subject = build_proven_subject(height: proof_height)
      tracker = spv_tracker_for(chain_committing_to(subject.merkle_path.compute_root))

      result = importer_with(tracker).import(
        tx: atomic_beef_for(subject),
        description: 'spv_headers consistent import',
        labels: ['incoming'],
        outputs: root_internalize_outputs
      )

      expect(result).to eq({ accepted: true })

      action = store.find_action(wtxid: subject.wtxid)
      expect(action).not_to be_nil
      expect(action[:broadcast_intent]).to eq('none')
      expect(action[:outgoing]).to be(false)
      expect(store.find_proof(wtxid: subject.wtxid)).not_to be_nil
    end

    it 'rejects a tampered BEEF and leaves nothing behind' do
      subject = build_proven_subject(height: proof_height)
      tampered_root = SecureRandom.random_bytes(32)
      tracker = spv_tracker_for(chain_committing_to(tampered_root))

      expect do
        importer_with(tracker).import(
          tx: atomic_beef_for(subject),
          description: 'spv_headers tampered import',
          outputs: root_internalize_outputs
        )
      end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed/)

      # verify runs before any write, so the ingress never created a row.
      expect(store.find_action(wtxid: subject.wtxid)).to be_nil
      expect(store.find_proof(wtxid: subject.wtxid)).to be_nil
    end
  end

  # ------------------------------------------------------------------
  # The default trust model is untouched: the same consistent BEEF,
  # verified through the trusted-service ChainTracker, still passes.
  # ------------------------------------------------------------------
  describe 'default :trusted_service mode is unchanged' do
    it 'still verifies the same consistent BEEF via the trusted-service ChainTracker' do
      subject = build_proven_subject(height: proof_height)
      # The trusted-service tracker reads :get_block_header and trusts the
      # answer outright; the synthetic header at proof_height returns the
      # committed root, so the proof checks out.
      chain = chain_committing_to(subject.merkle_path.compute_root)
      tracker = BSV::Network::ChainTracker.new(store: store, services: stub_services(chain))
      importer = importer_with(tracker)

      expect { importer.send(:verify_incoming_transaction!, subject) }.not_to raise_error
    end

    it 'accepts the same consistent BEEF through #import on the default path' do
      subject = build_proven_subject(height: proof_height)
      chain = chain_committing_to(subject.merkle_path.compute_root)
      tracker = BSV::Network::ChainTracker.new(store: store, services: stub_services(chain))

      result = importer_with(tracker).import(
        tx: atomic_beef_for(subject),
        description: 'trusted_service consistent import',
        outputs: root_internalize_outputs
      )

      expect(result).to eq({ accepted: true })
      expect(store.find_action(wtxid: subject.wtxid)).not_to be_nil
    end
  end
end
