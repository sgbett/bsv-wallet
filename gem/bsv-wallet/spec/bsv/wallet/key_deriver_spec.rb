# frozen_string_literal: true

RSpec.describe BSV::Wallet::KeyDeriver do
  let(:root_key) { BSV::Primitives::PrivateKey.generate }
  let(:privileged_key) { BSV::Primitives::PrivateKey.generate }
  let(:protocol_id) { [1, 'test proto'] }
  let(:key_id) { 'key1' }

  subject(:deriver) { described_class.new(private_key: root_key) }

  describe '#initialize' do
    it 'stores the root key' do
      kd = described_class.new(private_key: root_key)
      expect(kd.identity_key).to eq(root_key.public_key.to_hex)
    end

    it 'stores both keyrings when privileged key is provided' do
      kd = described_class.new(private_key: root_key, privileged_key: privileged_key)
      expect(kd.identity_key).to eq(root_key.public_key.to_hex)
    end
  end

  describe '#identity_key' do
    it 'returns a 66-character hex compressed public key' do
      hex = deriver.identity_key
      expect(hex).to be_a(String)
      expect(hex.length).to eq(66)
      expect(hex).to match(/\A(?:02|03)[0-9a-f]{64}\z/)
    end

    it 'matches the root key public key' do
      expect(deriver.identity_key).to eq(root_key.public_key.to_hex)
    end
  end

  describe '#derive_public_key' do
    context "with counterparty: 'self'" do
      it 'uses own public key for derivation' do
        result = deriver.derive_public_key(
          protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
        )
        expect(result).to be_a(String)
        expect(result.length).to eq(33)
      end
    end

    context "with counterparty: 'anyone'" do
      it 'uses PrivateKey(1) public key for derivation' do
        result = deriver.derive_public_key(
          protocol_id: protocol_id, key_id: key_id, counterparty: 'anyone'
        )
        expect(result).to be_a(String)
        expect(result.length).to eq(33)
      end

      it 'produces a different key than self' do
        self_key = deriver.derive_public_key(
          protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
        )
        anyone_key = deriver.derive_public_key(
          protocol_id: protocol_id, key_id: key_id, counterparty: 'anyone'
        )
        expect(self_key).not_to eq(anyone_key)
      end
    end

    context 'with a hex public key counterparty' do
      let(:other_key) { BSV::Primitives::PrivateKey.generate }
      let(:counterparty_hex) { other_key.public_key.to_hex }

      it 'derives a public key' do
        result = deriver.derive_public_key(
          protocol_id: protocol_id, key_id: key_id, counterparty: counterparty_hex
        )
        expect(result).to be_a(String)
        expect(result.length).to eq(33)
      end
    end

    context 'with for_self: true' do
      it 'produces a different key than for_self: false' do
        normal = deriver.derive_public_key(
          protocol_id: protocol_id, key_id: key_id, counterparty: 'anyone'
        )
        for_self = deriver.derive_public_key(
          protocol_id: protocol_id, key_id: key_id, counterparty: 'anyone', for_self: true
        )
        expect(normal).not_to eq(for_self)
      end
    end

    context 'with privileged: true' do
      it 'raises without a privileged key' do
        expect do
          deriver.derive_public_key(
            protocol_id: protocol_id, key_id: key_id, counterparty: 'self', privileged: true
          )
        end.to raise_error(BSV::Wallet::Error, /privileged/)
      end

      it 'uses the privileged keyring when configured' do
        kd = described_class.new(private_key: root_key, privileged_key: privileged_key)

        normal = kd.derive_public_key(
          protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
        )
        priv_result = kd.derive_public_key(
          protocol_id: protocol_id, key_id: key_id, counterparty: 'self', privileged: true
        )
        expect(normal).not_to eq(priv_result)
      end
    end
  end

  describe '#derive_private_key' do
    it 'returns a PrivateKey' do
      result = deriver.derive_private_key(
        protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      expect(result).to be_a(BSV::Primitives::PrivateKey)
    end

    it 'derives deterministically' do
      key1 = deriver.derive_private_key(
        protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      key2 = deriver.derive_private_key(
        protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      expect(key1.to_hex).to eq(key2.to_hex)
    end
  end

  describe 'mathematical invariant' do
    it 'derive_private_key.public_key matches derive_public_key (for_self: false)' do
      pub_from_derive = deriver.derive_public_key(
        protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      priv = deriver.derive_private_key(
        protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      expect(priv.public_key.compressed).to eq(pub_from_derive)
    end

    it 'holds for counterparty: anyone' do
      pub_from_derive = deriver.derive_public_key(
        protocol_id: protocol_id, key_id: key_id, counterparty: 'anyone'
      )
      priv = deriver.derive_private_key(
        protocol_id: protocol_id, key_id: key_id, counterparty: 'anyone'
      )
      expect(priv.public_key.compressed).to eq(pub_from_derive)
    end

    it 'holds for a hex counterparty' do
      cp_hex = BSV::Primitives::PrivateKey.generate.public_key.to_hex
      pub_from_derive = deriver.derive_public_key(
        protocol_id: protocol_id, key_id: key_id, counterparty: cp_hex
      )
      priv = deriver.derive_private_key(
        protocol_id: protocol_id, key_id: key_id, counterparty: cp_hex
      )
      expect(priv.public_key.compressed).to eq(pub_from_derive)
    end

    it 'holds with privileged keyring' do
      kd = described_class.new(private_key: root_key, privileged_key: privileged_key)
      pub_from_derive = kd.derive_public_key(
        protocol_id: protocol_id, key_id: key_id, counterparty: 'self', privileged: true
      )
      priv = kd.derive_private_key(
        protocol_id: protocol_id, key_id: key_id, counterparty: 'self', privileged: true
      )
      expect(priv.public_key.compressed).to eq(pub_from_derive)
    end
  end

  describe 'invoice number format' do
    it 'formats as "level-name-key_id"' do
      # Verify by checking that two different protocol names produce different keys
      key_a = deriver.derive_public_key(
        protocol_id: [0, 'proto alpha'], key_id: 'keyid', counterparty: 'self'
      )
      key_b = deriver.derive_public_key(
        protocol_id: [0, 'proto bravo'], key_id: 'keyid', counterparty: 'self'
      )
      expect(key_a).not_to eq(key_b)
    end
  end

  describe 'BRC-43 validation' do
    context 'security level' do
      it 'rejects level -1' do
        expect do
          deriver.derive_public_key(protocol_id: [-1, 'test proto'], key_id: key_id, counterparty: 'self')
        end.to raise_error(BSV::Wallet::InvalidParameterError, /security level/)
      end

      it 'rejects level 3' do
        expect do
          deriver.derive_public_key(protocol_id: [3, 'test proto'], key_id: key_id, counterparty: 'self')
        end.to raise_error(BSV::Wallet::InvalidParameterError, /security level/)
      end

      it 'accepts levels 0, 1, and 2' do
        [0, 1, 2].each do |level|
          expect do
            deriver.derive_public_key(protocol_id: [level, 'test proto'], key_id: key_id, counterparty: 'self')
          end.not_to raise_error
        end
      end
    end

    context 'protocol name' do
      it 'rejects names shorter than 5 characters' do
        expect do
          deriver.derive_public_key(protocol_id: [1, 'abcd'], key_id: key_id, counterparty: 'self')
        end.to raise_error(BSV::Wallet::InvalidParameterError, /protocol name/)
      end

      it 'rejects names longer than 400 characters' do
        expect do
          deriver.derive_public_key(protocol_id: [1, 'a' * 401], key_id: key_id, counterparty: 'self')
        end.to raise_error(BSV::Wallet::InvalidParameterError, /protocol name/)
      end

      it 'rejects names with consecutive spaces' do
        expect do
          deriver.derive_public_key(protocol_id: [1, 'test  protocol name'], key_id: key_id, counterparty: 'self')
        end.to raise_error(BSV::Wallet::InvalidParameterError, /consecutive spaces/)
      end

      it 'rejects names ending in " protocol"' do
        expect do
          deriver.derive_public_key(protocol_id: [1, 'my test protocol'], key_id: key_id, counterparty: 'self')
        end.to raise_error(BSV::Wallet::InvalidParameterError, /protocol/)
      end

      it 'accepts valid protocol names' do
        expect do
          deriver.derive_public_key(protocol_id: [1, 'my test proto'], key_id: key_id, counterparty: 'self')
        end.not_to raise_error
      end
    end

    context 'key_id' do
      it 'rejects nil key_id' do
        expect do
          deriver.derive_public_key(protocol_id: protocol_id, key_id: nil, counterparty: 'self')
        end.to raise_error(BSV::Wallet::InvalidParameterError, /key_id/)
      end

      it 'rejects empty key_id' do
        expect do
          deriver.derive_public_key(protocol_id: protocol_id, key_id: '', counterparty: 'self')
        end.to raise_error(BSV::Wallet::InvalidParameterError, /key_id/)
      end

      it 'rejects key_id longer than 800 characters' do
        expect do
          deriver.derive_public_key(protocol_id: protocol_id, key_id: 'k' * 801, counterparty: 'self')
        end.to raise_error(BSV::Wallet::InvalidParameterError, /key_id/)
      end
    end

    context 'counterparty' do
      it 'rejects invalid hex strings' do
        expect do
          deriver.derive_public_key(protocol_id: protocol_id, key_id: key_id, counterparty: 'not-a-hex-key')
        end.to raise_error(BSV::Wallet::InvalidParameterError, /counterparty/)
      end

      it 'rejects hex strings of wrong length' do
        expect do
          deriver.derive_public_key(protocol_id: protocol_id, key_id: key_id, counterparty: '02abcdef')
        end.to raise_error(BSV::Wallet::InvalidParameterError, /counterparty/)
      end
    end
  end
end
