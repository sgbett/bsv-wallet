# frozen_string_literal: true

# +Engine#import_wallet+ basket forwarding (#462, Phase 3).
#
# Scanning import threads +basket:+ through to the per-UTXO
# +import_utxo+ call so the scanning form has the same basket-routing
# capability that pinpoint import gained at #436. Default +nil+ keeps
# the existing behaviour (imported funds land in the unbasketed pool).

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Engine do # rubocop:disable RSpec/SpecFilePathFormat
  include_context 'engine setup'

  metadata[:skip_reserve] = true

  let(:network_provider) { double(:network_provider) }
  let(:engine) do
    described_class.new(
      store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
      key_deriver: key_deriver, network_provider: network_provider, network: :mainnet
    )
  end

  describe '#import_wallet basket forwarding' do
    let(:utxo) { { 'tx_hash' => 'a' * 64, 'tx_pos' => 0 } }
    let(:utxos_response) do
      instance_double(BSV::Network::ProtocolResponse,
                      http_success?: true, http_not_found?: false, data: [utxo])
    end

    before do
      allow(network_provider).to receive(:call).and_return(utxos_response)
      allow(engine).to receive(:import_utxo).and_return({ imported: true })
    end

    it 'threads :basket through to import_utxo' do
      engine.import_wallet(basket: 'received')
      expect(engine).to have_received(:import_utxo).with(
        hash_including(basket: 'received')
      )
    end

    it 'defaults basket to nil (preserves unbasketed pool behaviour)' do
      engine.import_wallet
      expect(engine).to have_received(:import_utxo).with(
        hash_including(basket: nil)
      )
    end

    it 'forwards no_send + accept_delayed_broadcast alongside basket' do
      engine.import_wallet(basket: 'b', no_send: true, accept_delayed_broadcast: false)
      expect(engine).to have_received(:import_utxo).with(
        hash_including(basket: 'b', no_send: true, accept_delayed_broadcast: false)
      )
    end
  end
end
