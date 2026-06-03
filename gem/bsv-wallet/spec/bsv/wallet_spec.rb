# frozen_string_literal: true

RSpec.describe BSV::Wallet do
  describe BSV::Wallet::Interface::BRC100 do
    subject { klass.new }

    let(:klass) do
      Class.new { include BSV::Wallet::Interface::BRC100 }
    end

    it 'defines all 28 BRC-100 methods' do
      expected_methods = %i[
        create_action sign_action abort_action list_actions
        internalize_action list_outputs relinquish_output
        get_public_key
        reveal_counterparty_key_linkage reveal_specific_key_linkage
        encrypt decrypt create_hmac verify_hmac
        create_signature verify_signature
        acquire_certificate list_certificates prove_certificate
        relinquish_certificate
        discover_by_identity_key discover_by_attributes
        authenticated? wait_for_authentication
        get_height get_header_for_height get_network get_version
      ]

      expected_methods.each do |method|
        expect(subject).to respond_to(method),
                           "expected wallet to respond to ##{method}"
      end
    end

    it 'raises NotImplementedError for unimplemented methods' do
      expect { subject.get_height }.to raise_error(NotImplementedError)
    end
  end

  describe BSV::Wallet::Interface::Store do
    subject { klass.new }

    let(:klass) do
      Class.new { include BSV::Wallet::Interface::Store }
    end

    it 'defines action lifecycle methods' do
      %i[create_action sign_action promote_action link_proof abort_action].each do |method|
        expect(subject).to respond_to(method),
                           "expected store to respond to ##{method}"
      end
    end

    it 'defines query methods' do
      %i[find_action query_actions query_outputs].each do |method|
        expect(subject).to respond_to(method),
                           "expected store to respond to ##{method}"
      end
    end

    it 'defines label, tag, and basket methods' do
      %i[find_or_create_labels find_or_create_tags find_or_create_basket label_action].each do |method|
        expect(subject).to respond_to(method),
                           "expected store to respond to ##{method}"
      end
    end

    it 'defines certificate methods' do
      %i[save_certificate query_certificates delete_certificate].each do |method|
        expect(subject).to respond_to(method),
                           "expected store to respond to ##{method}"
      end
    end

    it 'defines settings methods' do
      %i[get_setting set_setting].each do |method|
        expect(subject).to respond_to(method),
                           "expected store to respond to ##{method}"
      end
    end

    it 'defines UTXO selection and reaper methods' do
      %i[find_spendable reap_stale_actions relinquish_output].each do |method|
        expect(subject).to respond_to(method),
                           "expected store to respond to ##{method}"
      end
    end
  end

  describe BSV::Wallet::Interface::UTXOPool do
    subject { klass.new }

    let(:klass) do
      Class.new { include BSV::Wallet::Interface::UTXOPool }
    end

    it 'defines selection strategy methods' do
      %i[select release balance].each do |method|
        expect(subject).to respond_to(method),
                           "expected UTXO pool to respond to ##{method}"
      end
    end
  end

  describe BSV::Wallet::Error do
    it 'carries a machine-readable code' do
      error = described_class.new('something went wrong', code: 42)
      expect(error.message).to eq('something went wrong')
      expect(error.code).to eq(42)
    end

    it 'defaults code to 1' do
      error = described_class.new('oops')
      expect(error.code).to eq(1)
    end

    it 'is a StandardError' do
      expect(described_class.ancestors).to include(StandardError)
    end
  end
end
