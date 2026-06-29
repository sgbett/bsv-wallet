# frozen_string_literal: true

require_relative '../wallet/store/shared_context'
require_relative 'synthetic_chain'

# HeaderSyncer: fetch → validate → persist the locally-validated header
# chain (#335). Uses a deterministic synthetic regtest chain (no live
# network) anchored at an injected checkpoint, with +services.call+ stubbed
# per height. Persistence is real (the +:store+ shared context), so the
# append-or-reject store path and the +validated_tip+ reader are exercised
# end to end. Runs on SQLite by default; Postgres is QA-verified.
RSpec.describe BSV::Network::HeaderSyncer, :store do
  subject(:syncer) { described_class.new(store: store, services: services, checkpoint: checkpoint) }

  let(:start_height) { 955_000 }
  let(:chain)        { SyntheticChain.build(start_height: start_height, count: 12) }
  let(:checkpoint)   { SyntheticChain.checkpoint_for(chain, start_height) }
  let(:services)     { instance_double(BSV::Network::Services) }

  # Stub the service to answer every requested height from the synthetic
  # chain (and 404-shaped error for heights outside it).
  def stub_chain!(override: {})
    allow(services).to receive(:call) do |command, height|
      raise "unexpected command #{command}" unless command == :get_block_header

      if override.key?(height)
        override[height]
      elsif chain.key?(height)
        SyntheticChain.success_response(chain[height])
      else
        SyntheticChain.error_response
      end
    end
  end

  describe '#sync_to!' do
    it 'seeds the checkpoint and validates+persists a clean chain' do
      stub_chain!
      tip = syncer.sync_to!(start_height + 5)

      expect(tip).to eq(start_height + 5)
      (start_height..(start_height + 5)).each do |h|
        expect(store.header_at(height: h)).to eq(chain[h].raw)
      end
      expect(store.validated_tip(from_height: start_height)).to eq(start_height + 5)
    end

    it 'persists the checkpoint header row as the trust anchor on first sync' do
      stub_chain!
      syncer.sync_to!(start_height) # target == checkpoint: seed only
      expect(store.header_at(height: start_height)).to eq(chain[start_height].raw)
    end

    it 'is O(1) on a second nearby call — no further fetches past the synced tip' do
      stub_chain!
      syncer.sync_to!(start_height + 4)
      # Re-syncing to an already-covered height issues no get_block_header calls.
      allow(services).to receive(:call).and_raise('should not fetch')
      expect { syncer.sync_to!(start_height + 3) }.not_to raise_error
    end

    context 'fail-closed' do
      it 'STOPS at an injected bad-PoW header and does not advance past it' do
        # Forge a header at start_height+3 whose nonce yields a hash ABOVE
        # the (here, deliberately hard) target so valid_pow? is false.
        bad = forge_bad_pow(chain[start_height + 3])
        stub_chain!(override: { (start_height + 3) => SyntheticChain.success_response(bad) })

        tip = syncer.sync_to!(start_height + 6)

        expect(tip).to eq(start_height + 2) # last good height
        expect(store.header_at(height: start_height + 3)).to be_nil
        expect(store.validated_tip(from_height: start_height)).to eq(start_height + 2)
      end

      it 'STOPS at a broken link (prev_hash does not chain onto the tip)' do
        # A valid-PoW header whose prev_hash points nowhere in our chain.
        broken = SyntheticChain.mine(
          prev_wire: SecureRandom.random_bytes(32),
          merkle_wire: SecureRandom.random_bytes(32),
          time: 1_700_000_999
        )
        stub_chain!(override: { (start_height + 3) => SyntheticChain.success_response(broken) })

        tip = syncer.sync_to!(start_height + 6)

        expect(tip).to eq(start_height + 2)
        expect(store.header_at(height: start_height + 3)).to be_nil
      end

      it 'STOPS on a missing (failed) service response' do
        stub_chain!(override: { (start_height + 3) => SyntheticChain.error_response })

        tip = syncer.sync_to!(start_height + 6)

        expect(tip).to eq(start_height + 2)
        expect(store.header_at(height: start_height + 3)).to be_nil
      end

      it 'STOPS on a nil service response' do
        stub_chain!(override: { (start_height + 3) => nil })

        tip = syncer.sync_to!(start_height + 6)

        expect(tip).to eq(start_height + 2)
      end
    end

    context 'DoS bound' do
      it 'refuses a target far beyond tip + MAX_SYNC_SPAN without fetching' do
        # Seed only; then ask for an absurd height. The cap must trip before
        # any get_block_header call fires.
        stub_chain!
        syncer.sync_to!(start_height) # seed anchor

        absurd = start_height + described_class::MAX_SYNC_SPAN + 1
        # Re-stub every service call to raise: if the DoS guard fetched even
        # once, this example would error. It returning cleanly proves no fetch.
        allow(services).to receive(:call).and_raise('DoS: must not fetch')

        expect(syncer.sync_to!(absurd)).to eq(start_height)
      end
    end
  end

  describe '#validated_tip' do
    it 'seeds from the checkpoint when the chain is unseeded' do
      stub_chain!
      expect(syncer.validated_tip).to eq(start_height)
    end

    it 'reflects persisted progress after a sync' do
      stub_chain!
      syncer.sync_to!(start_height + 3)
      expect(syncer.validated_tip).to eq(start_height + 3)
    end
  end

  # Forge a header that fails PoW: keep the (valid) chain linkage but pin a
  # hard +bits+ and a nonce known to leave the hash above target. We mine
  # AGAINST an unsatisfiable target by flipping the easy regtest target to a
  # minimal one — every hash then exceeds it, so valid_pow? is false while
  # the prev linkage to the synthetic tip still holds.
  def forge_bad_pow(parent_position_header)
    prev = chain[start_height + 2].block_hash # links onto the validated tip
    merkle = SecureRandom.random_bytes(32)
    # bits = 0x03000001 → target = 0x000001 (tiny); virtually every hash > target.
    raw = [parent_position_header.version].pack('V') + prev + merkle +
          [parent_position_header.time].pack('V') + [0x03000001].pack('V') + [0].pack('V')
    header = BSV::Network::BlockHeader.parse(raw)
    raise 'forged header unexpectedly valid PoW' if header.valid_pow?

    header
  end
end
