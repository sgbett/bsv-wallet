# frozen_string_literal: true

# Import-path network retry + clean-error behaviour (#375).
#
# +fetch_proof_for_imported_utxo!+ previously built its failure message from
# +ProtocolResponse#status_code+ (which does not exist — the accessor is
# +#code+), so a non-success response raised +NoMethodError+ during error
# construction instead of the intended +BSV::Wallet::Error+. It also called
# the raw provider with no retry, so a transient HTTP 429 hard-failed the
# import (flaking CI). These specs pin both: the clean error with the HTTP
# +code+, and retry-on-retryable with backoff.

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Engine do # rubocop:disable RSpec/SpecFilePathFormat
  include_context 'engine setup'

  metadata[:skip_reserve] = true

  let(:dtxid) { 'a' * 64 }
  let(:network_provider) { double(:network_provider) }
  let(:engine) do
    described_class.new(
      store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
      key_deriver: key_deriver, network_provider: network_provider, network: :mainnet
    )
  end

  before { allow(engine).to receive(:backoff_sleep) }

  def response(http_success:, retryable: false, code: nil, data: nil)
    instance_double(BSV::Network::ProtocolResponse,
                    http_success?: http_success, retryable?: retryable,
                    code: code, data: data)
  end

  describe '#fetch_proof_for_imported_utxo!' do
    it 'raises a clean BSV::Wallet::Error citing the HTTP code on a terminal failure' do
      allow(network_provider).to receive(:call)
        .with(:get_tx_details, txid: dtxid)
        .and_return(response(http_success: false, retryable: false, code: '404'))

      expect { engine.send(:fetch_proof_for_imported_utxo!, dtxid) }
        .to raise_error(BSV::Wallet::Error, /get_tx_details failed \(HTTP 404\)/)
    end

    it 'does not retry a non-retryable failure' do
      allow(network_provider).to receive(:call)
        .with(:get_tx_details, txid: dtxid)
        .and_return(response(http_success: false, retryable: false, code: '404'))

      begin
        engine.send(:fetch_proof_for_imported_utxo!, dtxid)
      rescue BSV::Wallet::Error
        # expected
      end

      expect(network_provider).to have_received(:call).once
      expect(engine).not_to have_received(:backoff_sleep)
    end

    it 'retries a retryable 429 then proceeds once the provider recovers' do
      allow(network_provider).to receive(:call)
        .with(:get_tx_details, txid: dtxid)
        .and_return(
          response(http_success: false, retryable: true, code: '429'),
          response(http_success: true, data: {}) # success, but no blockheight
        )

      # Reaching the "not confirmed" guard proves the retry recovered and the
      # loop exited on success rather than failing on the 429.
      expect { engine.send(:fetch_proof_for_imported_utxo!, dtxid) }
        .to raise_error(BSV::Wallet::Error, /not confirmed/)
      expect(network_provider).to have_received(:call).twice
      expect(engine).to have_received(:backoff_sleep).once
    end

    it 'exhausts retries on a persistent 429 and raises a clean error' do
      allow(network_provider).to receive(:call)
        .with(:get_tx_details, txid: dtxid)
        .and_return(response(http_success: false, retryable: true, code: '429'))

      expect { engine.send(:fetch_proof_for_imported_utxo!, dtxid) }
        .to raise_error(BSV::Wallet::Error, /get_tx_details failed \(HTTP 429\)/)
      expect(network_provider).to have_received(:call)
        .exactly(BSV::Wallet::Engine::RETRYABLE_IMPORT_ATTEMPTS).times
      expect(engine).to have_received(:backoff_sleep)
        .exactly(BSV::Wallet::Engine::RETRYABLE_IMPORT_ATTEMPTS - 1).times
    end
  end
end
