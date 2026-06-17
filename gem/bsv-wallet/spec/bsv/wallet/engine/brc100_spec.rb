# frozen_string_literal: true

require 'bsv-wallet'
require 'bsv/wallet/engine'
require 'bsv/wallet/engine/brc100'

# Method-resolution-order regression spec for the Engine::BRC100 slice
# (#364, Phase 7 of the #291 "Monolith to Manageable" roadmap).
#
# The slice is a mixin facade: Engine includes Engine::BRC100, which
# itself includes the SDK contract Interface::BRC100. The expected
# ancestry is +Engine → Engine::BRC100 → Interface::BRC100+ so the
# 28 impls always beat the contract's +NotImplementedError+ stubs.
#
# These assertions are belt-and-braces. A future reorder of `include`
# lines, a missed move, or an accidental stub-shadowing all show up
# here as a red spec rather than a silent +NotImplementedError+ at
# runtime.
# Frozen list — a future contract change must force a deliberate edit.
# Defined at file scope so the rubocop RSpec/LeakyLocalVariable cop is
# satisfied; the iteration below builds one +it+ per name at load time,
# so a regular +let+ wouldn't work (the array must exist before
# describe-block evaluation, not at example time).
BRC100_SPEC_METHODS = %i[
  create_action sign_action abort_action list_actions internalize_action
  list_outputs relinquish_output
  get_public_key reveal_counterparty_key_linkage reveal_specific_key_linkage
  encrypt decrypt create_hmac verify_hmac create_signature verify_signature
  acquire_certificate list_certificates prove_certificate relinquish_certificate
  discover_by_identity_key discover_by_attributes
  authenticated? wait_for_authentication
  get_height get_header_for_height get_network get_version
].freeze

RSpec.describe BSV::Wallet::Engine::BRC100 do
  it 'covers exactly the 28 BRC-100 spec methods' do
    expect(BRC100_SPEC_METHODS.length).to eq(28)
  end

  describe 'method-resolution order' do
    it 'places Engine::BRC100 ahead of Interface::BRC100 in Engine.ancestors' do
      ancestors = BSV::Wallet::Engine.ancestors
      slice_idx = ancestors.index(described_class)
      contract_idx = ancestors.index(BSV::Wallet::Interface::BRC100)

      expect(slice_idx).not_to be_nil, 'Engine::BRC100 not in ancestry'
      expect(contract_idx).not_to be_nil, 'Interface::BRC100 not in ancestry'
      expect(slice_idx).to be < contract_idx,
                           "expected Engine::BRC100 (#{slice_idx}) to precede " \
                           "Interface::BRC100 (#{contract_idx}) — impls must beat stubs"
    end

    it 'inherits Interface::BRC100 transitively through Engine::BRC100' do
      # Engine::BRC100 itself includes the SDK contract.
      expect(described_class.ancestors).to include(BSV::Wallet::Interface::BRC100)
      # Engine acquires it via Engine::BRC100, no direct include needed.
      expect(BSV::Wallet::Engine.ancestors).to include(BSV::Wallet::Interface::BRC100)
    end
  end

  describe 'each of the 28 methods' do
    BRC100_SPEC_METHODS.each do |name|
      it "##{name} is owned by Engine::BRC100 (not Engine, not Interface::BRC100)" do
        owner = BSV::Wallet::Engine.instance_method(name).owner
        expect(owner).to eq(described_class),
                         "expected #{name} on Engine::BRC100, found on #{owner} — " \
                         'stub-shadowing or missed move?'
      end
    end
  end

  describe 'Engine.instance_methods(false)' do
    it 'no longer defines any of the 28 directly on Engine' do
      direct = BSV::Wallet::Engine.instance_methods(false)
      leaked = BRC100_SPEC_METHODS & direct
      expect(leaked).to eq([]),
                        "expected the 28 to live on Engine::BRC100, but Engine still owns: #{leaked.inspect}"
    end
  end

  describe 'smoke: a moved impl resolves to the slice, not the contract' do
    # Reach for the cheapest no-side-effect impl: get_network just reads @network_name.
    it '#get_network returns a real value, not NotImplementedError' do
      engine = BSV::Wallet::Engine.allocate
      engine.instance_variable_set(:@network_name, :mainnet)

      expect { engine.get_network }.not_to raise_error
      expect(engine.get_network).to eq(network: :mainnet)
    end
  end
end
