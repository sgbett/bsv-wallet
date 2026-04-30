# frozen_string_literal: true

RSpec.describe BSV::Wallet do
  describe BSV::Wallet::Interface::BRC100 do
    let(:klass) do
      Class.new { include BSV::Wallet::Interface::BRC100 }
    end

    subject { klass.new }

    it 'defines all 28 BRC-100 methods' do
      expected_methods = %i[
        create_action sign_action abort_action list_actions
        internalise_action list_outputs relinquish_output
        public_key
        reveal_counterparty_key_linkage reveal_specific_key_linkage
        encrypt decrypt create_hmac verify_hmac
        create_signature verify_signature
        acquire_certificate list_certificates prove_certificate
        relinquish_certificate
        discover_by_identity_key discover_by_attributes
        authenticated? wait_for_authentication
        height header_for_height network version
      ]

      expected_methods.each do |method|
        expect(subject).to respond_to(method),
          "expected wallet to respond to ##{method}"
      end
    end

    it 'raises NotImplementedError for unimplemented methods' do
      expect { subject.height }.to raise_error(NotImplementedError)
    end
  end

  describe BSV::Wallet::Interface::Store do
    let(:klass) do
      Class.new { include BSV::Wallet::Interface::Store }
    end

    subject { klass.new }

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
    let(:klass) do
      Class.new { include BSV::Wallet::Interface::UTXOPool }
    end

    subject { klass.new }

    it 'defines selection strategy methods' do
      %i[select release balance].each do |method|
        expect(subject).to respond_to(method),
          "expected UTXO pool to respond to ##{method}"
      end
    end
  end

  describe BSV::Wallet::Interface::BroadcastQueue do
    let(:klass) do
      Class.new { include BSV::Wallet::Interface::BroadcastQueue }
    end

    subject { klass.new }

    it 'defines broadcast lifecycle methods' do
      %i[submit process_pending status].each do |method|
        expect(subject).to respond_to(method),
          "expected broadcast queue to respond to ##{method}"
      end
    end
  end

  describe BSV::Wallet::Interface::ProofStore do
    let(:klass) do
      Class.new { include BSV::Wallet::Interface::ProofStore }
    end

    subject { klass.new }

    it 'defines proof storage methods' do
      %i[save_proof find_proof proof_exists? request_proof process_pending].each do |method|
        expect(subject).to respond_to(method),
          "expected proof store to respond to ##{method}"
      end
    end
  end

  describe BSV::Wallet::Error do
    it 'carries a machine-readable code' do
      error = BSV::Wallet::Error.new('something went wrong', 42)
      expect(error.message).to eq('something went wrong')
      expect(error.code).to eq(42)
    end

    it 'defaults code to 1' do
      error = BSV::Wallet::Error.new('oops')
      expect(error.code).to eq(1)
    end

    it 'is a StandardError' do
      expect(BSV::Wallet::Error.ancestors).to include(StandardError)
    end
  end
end
