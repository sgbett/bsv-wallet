# frozen_string_literal: true

require_relative '../../../tasks/docs_guard'

RSpec.describe DocsGuard::CodeIndex do
  let(:hydrator) do
    Class.new do
      def wire; end

      def self.build; end

      private

      def submit; end
    end
  end

  let(:refiner) do
    Module.new do
      refine(String) { def to_fixture_dtxid; end }
    end
  end

  let(:modules) { [DocsGuardFixture, DocsGuardFixture::Engine, DocsGuardFixture::Engine::Hydrator, DocsGuardFixture::Txid] }
  let(:index) { described_class.new(modules) }

  before do
    stub_const('DocsGuardFixture::Engine::Hydrator', hydrator)
    stub_const('DocsGuardFixture::Engine::Hydrator::LIMIT', 3)
    stub_const('DocsGuardFixture::Txid', refiner)
  end

  it 'resolves a constant by its full name or by any trailing part of it' do
    expect(%w[DocsGuardFixture::Engine::Hydrator Engine::Hydrator Hydrator].map { |c| index.resolves?(c) }).to all(be(true))
  end

  it 'resolves a value constant' do
    expect(index.resolves?('Hydrator::LIMIT')).to be(true)
  end

  it 'fails a constant nothing defines' do
    expect(index.resolves?('Engine::Transmission')).to be(false)
  end

  it 'resolves instance methods of any visibility' do
    expect([index.resolves?('Hydrator', '#', 'wire'), index.resolves?('Engine::Hydrator', '#', 'submit')]).to eq([true, true])
  end

  it 'fails a method the class no longer has' do
    expect(index.resolves?('Hydrator', '#', 'replace_known_ancestors!')).to be(false)
  end

  it 'does not count methods every object has' do
    expect(%w[select format send].map { |m| index.resolves?('Hydrator', '#', m) }).to all(be(false))
  end

  it 'still resolves those methods on the classes that define them' do
    object_index = described_class.new([Object])

    expect(object_index.resolves?('Object', '#', 'send')).to be(true)
  end

  it 'resolves class methods, and .new, but not methods every class has' do
    results = %w[build new puts].map { |m| index.resolves?('Hydrator', '.', m) }

    expect(results).to eq([true, true, false])
  end

  it 'counts as universal a module mixed into every class after this file loaded' do
    mixin = Module.new { def fixture_to_json; end }
    hydrator.extend(mixin)
    allow(Class).to(receive(:ancestors).and_wrap_original { |original| original.call + [mixin] })

    expect(index.resolves?('Hydrator', '.', 'fixture_to_json')).to be(false)
  end

  it 'resolves a method that exists only through a refinement' do
    string_index = described_class.new(modules + [String])

    expect(string_index.resolves?('String', '#', 'to_fixture_dtxid')).to be(true)
  end

  it 'names the candidates a short name could mean' do
    expect(index.candidates_for('Hydrator')).to eq(['DocsGuardFixture::Engine::Hydrator'])
  end

  describe 'when a wallet class shares its name with an SDK class' do
    let(:lib) { File.expand_path('../../../lib', __dir__) }
    let(:sdk_deriver) { BSV::Wallet::ProtoWallet::KeyDeriver }
    let(:wallet_index) { described_class.new([BSV::Wallet::KeyDeriver, sdk_deriver], local_root: lib) }

    it 'checks the wallet class only' do
      expect(wallet_index.resolves?('KeyDeriver', '#', 'reveal_counterparty_secret')).to be(false)
    end

    it 'still resolves the SDK class by its qualified name' do
      expect(wallet_index.resolves?('ProtoWallet::KeyDeriver', '#', 'reveal_counterparty_secret')).to be(true)
    end
  end
end
