# frozen_string_literal: true

require 'bsv-wallet'
require 'bsv/wallet/engine'
require 'bsv/wallet/brc100'

# Class-shape regression spec for the BRC100 wrap layer.
#
# Lifecycle of this class:
# - #364 Phase 7 of #291: introduced as +Engine::BRC100+ mixin.
# - #400 Stage 1 of #396: relocated to sibling +BSV::Wallet::BRC100+
#   (still a mixin).
# - #405 Stage 3 of #396: promoted from +module+ to +class+ composed
#   over an Engine instance via +BRC100.new(engine)+ / +Engine#brc100+.
#
# Post-Stage-3 invariants this spec locks in:
#   - BRC100 is a +Class+ (not a +Module+).
#   - +BSV::Wallet::Engine+ does NOT include BRC100 (the mixin is gone).
#   - +Engine#brc100+ returns a memoised +BRC100+ instance wrapping
#     +self+.
#   - BRC100 still +include+s the SDK contract +Interface::BRC100+ so
#     unimplemented methods would fall through to +NotImplementedError+
#     stubs (currently all 28 are implemented).
#   - The 28 BRC-100 spec method names land on Engine TOO (post-#405
#     commit 4) as the wallet-vocab primitive surface — but those are
#     a different shape (wallet vocab) from BRC100's wraps.
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

RSpec.describe BSV::Wallet::BRC100 do
  it 'covers exactly the 28 BRC-100 spec methods' do
    expect(BRC100_SPEC_METHODS.length).to eq(28)
  end

  it 'no longer exists at the pre-#400 path BSV::Wallet::Engine::BRC100 (no deprecation alias)' do
    expect { BSV::Wallet::Engine.const_get(:BRC100, false) }.to raise_error(NameError)
  end

  describe 'class shape (#405 Stage 3)' do
    it 'is a Class (was a Module pre-#405)' do
      expect(described_class).to be_a(Class)
    end

    it 'still +include+s the SDK contract Interface::BRC100' do
      expect(described_class.ancestors).to include(BSV::Wallet::Interface::BRC100)
    end

    it 'is NOT in Engine.ancestors (mixin removed)' do
      expect(BSV::Wallet::Engine.ancestors).not_to include(described_class)
    end

    it 'wraps an engine reference passed to .new' do
      fake_engine = Object.new
      instance = described_class.new(fake_engine)
      expect(instance.engine).to be(fake_engine)
    end
  end

  describe 'each of the 28 methods' do
    BRC100_SPEC_METHODS.each do |name|
      it "##{name} is defined on BSV::Wallet::BRC100" do
        owner = described_class.instance_method(name).owner
        expect(owner).to eq(described_class),
                         "expected #{name} on BSV::Wallet::BRC100, found on #{owner} — " \
                         'stub-shadowing or missed move?'
      end
    end
  end

  describe 'Engine#brc100 accessor' do
    let(:engine) { instance_double(BSV::Wallet::Engine) }

    it 'is callable on a real Engine' do
      real_engine = BSV::Wallet::Engine.allocate
      expect(real_engine.brc100).to be_a(described_class)
    end

    it 'is memoised — returns the same instance across calls' do
      real_engine = BSV::Wallet::Engine.allocate
      first = real_engine.brc100
      second = real_engine.brc100
      expect(first).to be(second)
    end
  end

  describe 'smoke: a method delegates to the engine primitive' do
    it '#get_network routes through @engine.get_network' do
      # +BRC100#get_network+ wraps +Engine#get_network+'s return
      # (wallet vocab: the bare network symbol) in BRC-100 vocab
      # +{ network: symbol }+.
      fake_engine = instance_double(BSV::Wallet::Engine, get_network: :mainnet)
      brc100 = described_class.new(fake_engine)

      expect(brc100.get_network).to eq(network: :mainnet)
    end
  end

  # The wrappers continue to ACCEPT +seek_permission:+ from BRC-100
  # callers (it's part of the BRC-100 method contract), even though
  # they no longer forward it to Engine. If a future "cleanup" removed
  # the kwarg from the wrapper signatures thinking it was unused, an
  # external caller passing +seek_permission: true+ would hit
  # +ArgumentError+. These tests lock the wrapper-side acceptance in.
  describe 'BRC-100 contract: wrappers still accept seek_permission:' do
    let(:fake_engine) { instance_double(BSV::Wallet::Engine) }
    let(:brc100) { described_class.new(fake_engine) }

    it '#list_actions accepts seek_permission: without raising' do
      allow(fake_engine).to receive(:list_actions).and_return(total: 0, actions: [])
      expect { brc100.list_actions(labels: [], seek_permission: false) }.not_to raise_error
    end

    it '#internalize_action accepts seek_permission: without raising' do
      allow(fake_engine).to receive(:import_beef).and_return(accepted: true)
      expect do
        brc100.internalize_action(tx: 'beef'.b, outputs: [],
                                  description: 'internalize smoke',
                                  seek_permission: false)
      end.not_to raise_error
    end
  end

  describe '#list_outputs basket required (BRC-100 spec contract)' do
    let(:fake_engine) { instance_double(BSV::Wallet::Engine) }
    let(:brc100) { described_class.new(fake_engine) }

    it 'raises ArgumentError when basket is nil' do
      expect { brc100.list_outputs(basket: nil) }
        .to raise_error(ArgumentError, /basket: required/)
    end

    it 'raises ArgumentError when basket is empty string' do
      expect { brc100.list_outputs(basket: '') }
        .to raise_error(ArgumentError, /basket: required/)
    end

    it 'raises ArgumentError when basket is whitespace-only' do
      expect { brc100.list_outputs(basket: '   ') }
        .to raise_error(ArgumentError, /basket: required/)
    end

    it 'delegates to engine.spendable_outputs when basket is supplied' do
      allow(fake_engine).to receive(:spendable_outputs)
        .with(hash_including(basket: 'wallet'))
        .and_return(total: 0, outputs: [])
      expect(brc100.list_outputs(basket: 'wallet')).to eq(total_outputs: 0, outputs: [])
    end

    it 'trims leading/trailing whitespace before delegating to engine' do
      # Per BRC-100 §"Logical Validation Procedures" — interoperable SDK
      # validation trims identifiers before enforcing length limits.
      allow(fake_engine).to receive(:spendable_outputs)
        .with(hash_including(basket: 'wallet'))
        .and_return(total: 0, outputs: [])
      brc100.list_outputs(basket: '  wallet  ')
      expect(fake_engine).to have_received(:spendable_outputs)
        .with(hash_including(basket: 'wallet'))
    end
  end
end
