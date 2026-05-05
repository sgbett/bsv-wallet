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

  describe '#encrypt / #decrypt' do
    let(:plaintext) { 'hello world'.b }

    it 'round-trips: encrypt then decrypt returns original plaintext' do
      ciphertext = deriver.encrypt(
        plaintext: plaintext, protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      result = deriver.decrypt(
        ciphertext: ciphertext, protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      expect(result).to eq(plaintext)
    end

    it 'round-trips empty plaintext' do
      ciphertext = deriver.encrypt(
        plaintext: ''.b, protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      result = deriver.decrypt(
        ciphertext: ciphertext, protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      expect(result).to eq(''.b)
    end

    it 'round-trips with counterparty self' do
      ciphertext = deriver.encrypt(
        plaintext: plaintext, protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      result = deriver.decrypt(
        ciphertext: ciphertext, protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      expect(result).to eq(plaintext)
    end

    it 'produces different ciphertexts for different counterparties' do
      other_key = BSV::Primitives::PrivateKey.generate
      ct_self = deriver.encrypt(
        plaintext: plaintext, protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      ct_other = deriver.encrypt(
        plaintext: plaintext, protocol_id: protocol_id, key_id: key_id,
        counterparty: other_key.public_key.to_hex
      )
      expect(ct_self).not_to eq(ct_other)
    end

    it 'produces different ciphertext with privileged: true' do
      kd = described_class.new(private_key: root_key, privileged_key: privileged_key)
      ct_normal = kd.encrypt(
        plaintext: plaintext, protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      ct_priv = kd.encrypt(
        plaintext: plaintext, protocol_id: protocol_id, key_id: key_id,
        counterparty: 'self', privileged: true
      )
      expect(ct_normal).not_to eq(ct_priv)
    end

    it 'raises CipherError when decrypting with wrong parameters' do
      ciphertext = deriver.encrypt(
        plaintext: plaintext, protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      expect do
        deriver.decrypt(
          ciphertext: ciphertext, protocol_id: protocol_id, key_id: 'wrong_key', counterparty: 'self'
        )
      end.to raise_error(OpenSSL::Cipher::CipherError)
    end

    it 'handles binary data correctly' do
      binary = (0..255).to_a.pack('C*')
      ciphertext = deriver.encrypt(
        plaintext: binary, protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      result = deriver.decrypt(
        ciphertext: ciphertext, protocol_id: protocol_id, key_id: key_id, counterparty: 'self'
      )
      expect(result).to eq(binary)
    end
  end

  describe '#create_hmac' do
    let(:data) { 'hello world'.b }
    let(:derivation_params) { { protocol_id: protocol_id, key_id: key_id, counterparty: 'self' } }

    it 'is deterministic: same inputs produce identical HMAC' do
      hmac1 = deriver.create_hmac(data: data, **derivation_params)
      hmac2 = deriver.create_hmac(data: data, **derivation_params)
      expect(hmac1).to eq(hmac2)
    end

    it 'returns a 32-byte value' do
      hmac = deriver.create_hmac(data: data, **derivation_params)
      expect(hmac.bytesize).to eq(32)
    end

    it 'produces a different HMAC for a different key_id' do
      hmac1 = deriver.create_hmac(data: data, **derivation_params)
      hmac2 = deriver.create_hmac(data: data, **derivation_params.merge(key_id: 'key2'))
      expect(hmac1).not_to eq(hmac2)
    end

    it 'produces a different HMAC for a different protocol_id' do
      hmac1 = deriver.create_hmac(data: data, **derivation_params)
      hmac2 = deriver.create_hmac(data: data, **derivation_params.merge(protocol_id: [2, 'other proto']))
      expect(hmac1).not_to eq(hmac2)
    end

    it 'produces a different HMAC for a different counterparty' do
      other_key = BSV::Primitives::PrivateKey.generate
      hmac1 = deriver.create_hmac(data: data, **derivation_params)
      hmac2 = deriver.create_hmac(data: data, **derivation_params.merge(counterparty: other_key.public_key.to_hex))
      expect(hmac1).not_to eq(hmac2)
    end

    it 'produces a different HMAC with privileged: true' do
      kd = described_class.new(private_key: root_key, privileged_key: privileged_key)
      hmac_normal = kd.create_hmac(data: data, **derivation_params)
      hmac_priv = kd.create_hmac(data: data, **derivation_params.merge(privileged: true))
      expect(hmac_normal).not_to eq(hmac_priv)
    end
  end

  describe '#create_signature / #verify_signature' do
    let(:data) { 'hello world'.b }
    let(:derivation_params) { { protocol_id: protocol_id, key_id: key_id, counterparty: 'self' } }

    describe 'round-trip with data:' do
      it 'signs and verifies successfully' do
        sig = deriver.create_signature(data: data, **derivation_params)
        expect(sig).to be_a(BSV::Primitives::Signature)

        valid = deriver.verify_signature(signature: sig, data: data, **derivation_params)
        expect(valid).to be true
      end
    end

    describe 'round-trip with hash_to_directly_sign / hash_to_directly_verify' do
      it 'signs and verifies with a pre-computed hash' do
        hash = BSV::Primitives::Digest.sha256(data)
        sig = deriver.create_signature(hash_to_directly_sign: hash, **derivation_params)

        valid = deriver.verify_signature(
          signature: sig, hash_to_directly_verify: hash, **derivation_params
        )
        expect(valid).to be true
      end
    end

    describe 'cross-verify: sign with data, verify with pre-computed hash' do
      it 'verifies when the hash matches the data' do
        sig = deriver.create_signature(data: data, **derivation_params)
        hash = BSV::Primitives::Digest.sha256(data)

        valid = deriver.verify_signature(
          signature: sig, hash_to_directly_verify: hash, **derivation_params
        )
        expect(valid).to be true
      end
    end

    describe 'wrong data' do
      it 'returns false when data does not match the signature' do
        sig = deriver.create_signature(data: data, **derivation_params)

        valid = deriver.verify_signature(signature: sig, data: 'wrong data'.b, **derivation_params)
        expect(valid).to be false
      end
    end

    describe 'wrong counterparty' do
      it 'returns false when counterparty does not match' do
        sig = deriver.create_signature(data: data, **derivation_params)
        other_key = BSV::Primitives::PrivateKey.generate

        valid = deriver.verify_signature(
          signature: sig, data: data,
          protocol_id: protocol_id, key_id: key_id,
          counterparty: other_key.public_key.to_hex
        )
        expect(valid).to be false
      end
    end

    describe 'for_self: true verification' do
      it 'verifies when signer and verifier are different derivers' do
        alice_key = BSV::Primitives::PrivateKey.generate
        bob_key = BSV::Primitives::PrivateKey.generate
        alice = described_class.new(private_key: alice_key)
        bob = described_class.new(private_key: bob_key)

        # Alice signs for Bob (counterparty = Bob's public key)
        sig = alice.create_signature(
          data: data, protocol_id: protocol_id, key_id: key_id,
          counterparty: bob_key.public_key.to_hex
        )

        # Bob verifies with for_self: true (counterparty = Alice's public key)
        valid = bob.verify_signature(
          signature: sig, data: data,
          protocol_id: protocol_id, key_id: key_id,
          counterparty: alice_key.public_key.to_hex,
          for_self: true
        )
        expect(valid).to be true
      end
    end

    describe 'privileged: true' do
      it 'uses the privileged keyring' do
        kd = described_class.new(private_key: root_key, privileged_key: privileged_key)

        sig_normal = kd.create_signature(data: data, **derivation_params)
        sig_priv = kd.create_signature(data: data, **derivation_params.merge(privileged: true))

        # Different keyrings produce different signatures
        expect(sig_normal.to_der).not_to eq(sig_priv.to_der)

        # Each verifies only with the matching keyring
        expect(kd.verify_signature(signature: sig_priv, data: data,
                                   **derivation_params.merge(privileged: true))).to be true
        expect(kd.verify_signature(signature: sig_priv, data: data, **derivation_params)).to be false
      end
    end

    describe 'error handling' do
      it 'raises when both data and hash are nil' do
        expect do
          deriver.create_signature(**derivation_params)
        end.to raise_error(BSV::Wallet::Error, /data or a pre-computed hash/)
      end

      it 'raises on verify when both data and hash are nil' do
        sig = deriver.create_signature(data: data, **derivation_params)
        expect do
          deriver.verify_signature(signature: sig, **derivation_params)
        end.to raise_error(BSV::Wallet::Error, /data or a pre-computed hash/)
      end
    end
  end

  describe '#reveal_counterparty_linkage' do
    let(:counterparty_key) { BSV::Primitives::PrivateKey.generate }
    let(:verifier_key) { BSV::Primitives::PrivateKey.generate }
    let(:counterparty_hex) { counterparty_key.public_key.to_hex }
    let(:verifier_hex) { verifier_key.public_key.to_hex }

    it 'returns a hash with all required keys' do
      result = deriver.reveal_counterparty_linkage(
        counterparty: counterparty_hex, verifier: verifier_hex
      )
      expect(result).to include(
        :prover, :verifier, :counterparty,
        :revelation_time, :encrypted_linkage, :encrypted_linkage_proof
      )
    end

    it 'sets prover to the identity key' do
      result = deriver.reveal_counterparty_linkage(
        counterparty: counterparty_hex, verifier: verifier_hex
      )
      expect(result[:prover]).to eq(deriver.identity_key)
    end

    it 'sets verifier and counterparty correctly' do
      result = deriver.reveal_counterparty_linkage(
        counterparty: counterparty_hex, verifier: verifier_hex
      )
      expect(result[:verifier]).to eq(verifier_hex)
      expect(result[:counterparty]).to eq(counterparty_hex)
    end

    it 'sets revelation_time to UTC ISO 8601' do
      result = deriver.reveal_counterparty_linkage(
        counterparty: counterparty_hex, verifier: verifier_hex
      )
      expect(result[:revelation_time]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it 'raises when counterparty is self' do
      expect do
        deriver.reveal_counterparty_linkage(counterparty: 'self', verifier: verifier_hex)
      end.to raise_error(BSV::Wallet::Error, /yourself/)
    end

    it 'raises when counterparty is anyone' do
      expect do
        deriver.reveal_counterparty_linkage(counterparty: 'anyone', verifier: verifier_hex)
      end.to raise_error(BSV::Wallet::Error, /anyone/)
    end

    it 'uses privileged keyring when privileged: true' do
      kd = described_class.new(private_key: root_key, privileged_key: privileged_key)
      normal = kd.reveal_counterparty_linkage(
        counterparty: counterparty_hex, verifier: verifier_hex
      )
      priv_result = kd.reveal_counterparty_linkage(
        counterparty: counterparty_hex, verifier: verifier_hex, privileged: true
      )
      expect(normal[:encrypted_linkage]).not_to eq(priv_result[:encrypted_linkage])
    end

    context 'integration: verifier can decrypt the linkage' do
      it 'decrypts to the ECDH shared secret' do
        result = deriver.reveal_counterparty_linkage(
          counterparty: counterparty_hex, verifier: verifier_hex
        )

        verifier_deriver = described_class.new(private_key: verifier_key)
        decrypted = verifier_deriver.decrypt(
          ciphertext: result[:encrypted_linkage],
          protocol_id: [2, 'counterparty linkage revelation'],
          key_id: result[:revelation_time],
          counterparty: deriver.identity_key
        )

        # The decrypted value should be 33 bytes (compressed point)
        expect(decrypted.bytesize).to eq(33)

        # Verify it matches the actual ECDH shared secret
        expected = root_key.derive_shared_secret(counterparty_key.public_key).compressed
        expect(decrypted).to eq(expected)
      end
    end

    context 'integration: Schnorr proof verifies' do
      it 'decrypted proof passes Schnorr.verify_proof' do
        result = deriver.reveal_counterparty_linkage(
          counterparty: counterparty_hex, verifier: verifier_hex
        )

        verifier_deriver = described_class.new(private_key: verifier_key)

        # Decrypt the linkage (shared secret)
        linkage = verifier_deriver.decrypt(
          ciphertext: result[:encrypted_linkage],
          protocol_id: [2, 'counterparty linkage revelation'],
          key_id: result[:revelation_time],
          counterparty: deriver.identity_key
        )
        shared_secret = BSV::Primitives::PublicKey.from_bytes(linkage)

        # Decrypt the proof
        proof_bin = verifier_deriver.decrypt(
          ciphertext: result[:encrypted_linkage_proof],
          protocol_id: [2, 'counterparty linkage revelation'],
          key_id: result[:revelation_time],
          counterparty: deriver.identity_key
        )
        proof = BSV::Primitives::Schnorr::Proof.from_binary(proof_bin)

        prover_pub = BSV::Primitives::PublicKey.from_hex(result[:prover])
        counterparty_pub = BSV::Primitives::PublicKey.from_hex(result[:counterparty])

        valid = BSV::Primitives::Schnorr.verify_proof(
          prover_pub, counterparty_pub, shared_secret, proof
        )
        expect(valid).to be true
      end
    end
  end

  describe '#reveal_specific_linkage' do
    let(:counterparty_key) { BSV::Primitives::PrivateKey.generate }
    let(:verifier_key) { BSV::Primitives::PrivateKey.generate }
    let(:counterparty_hex) { counterparty_key.public_key.to_hex }
    let(:verifier_hex) { verifier_key.public_key.to_hex }

    it 'returns a hash with all required keys' do
      result = deriver.reveal_specific_linkage(
        counterparty: counterparty_hex, verifier: verifier_hex,
        protocol_id: protocol_id, key_id: key_id
      )
      expect(result).to include(
        :prover, :verifier, :counterparty, :protocol_id, :key_id,
        :encrypted_linkage, :encrypted_linkage_proof, :proof_type
      )
    end

    it 'sets proof_type to 0' do
      result = deriver.reveal_specific_linkage(
        counterparty: counterparty_hex, verifier: verifier_hex,
        protocol_id: protocol_id, key_id: key_id
      )
      expect(result[:proof_type]).to eq(0)
    end

    it 'preserves protocol_id and key_id in the result' do
      result = deriver.reveal_specific_linkage(
        counterparty: counterparty_hex, verifier: verifier_hex,
        protocol_id: protocol_id, key_id: key_id
      )
      expect(result[:protocol_id]).to eq(protocol_id)
      expect(result[:key_id]).to eq(key_id)
    end

    it 'raises when counterparty is self' do
      expect do
        deriver.reveal_specific_linkage(
          counterparty: 'self', verifier: verifier_hex,
          protocol_id: protocol_id, key_id: key_id
        )
      end.to raise_error(BSV::Wallet::Error, /yourself/)
    end

    it 'raises when counterparty is anyone' do
      expect do
        deriver.reveal_specific_linkage(
          counterparty: 'anyone', verifier: verifier_hex,
          protocol_id: protocol_id, key_id: key_id
        )
      end.to raise_error(BSV::Wallet::Error, /anyone/)
    end

    it 'uses privileged keyring when privileged: true' do
      kd = described_class.new(private_key: root_key, privileged_key: privileged_key)
      normal = kd.reveal_specific_linkage(
        counterparty: counterparty_hex, verifier: verifier_hex,
        protocol_id: protocol_id, key_id: key_id
      )
      priv_result = kd.reveal_specific_linkage(
        counterparty: counterparty_hex, verifier: verifier_hex,
        protocol_id: protocol_id, key_id: key_id, privileged: true
      )
      expect(normal[:encrypted_linkage]).not_to eq(priv_result[:encrypted_linkage])
    end

    context 'integration: verifier can decrypt the linkage' do
      it 'decrypts to the HMAC key offset' do
        result = deriver.reveal_specific_linkage(
          counterparty: counterparty_hex, verifier: verifier_hex,
          protocol_id: protocol_id, key_id: key_id
        )

        verifier_deriver = described_class.new(private_key: verifier_key)
        derived_protocol = "specific linkage revelation #{protocol_id[0]} #{protocol_id[1]}"

        decrypted = verifier_deriver.decrypt(
          ciphertext: result[:encrypted_linkage],
          protocol_id: [2, derived_protocol],
          key_id: key_id,
          counterparty: deriver.identity_key
        )

        # The decrypted value should be 32 bytes (HMAC-SHA256)
        expect(decrypted.bytesize).to eq(32)

        # Verify it matches the actual HMAC key offset
        shared_secret = root_key.derive_shared_secret(counterparty_key.public_key)
        invoice = "#{protocol_id[0]}-#{protocol_id[1]}-#{key_id}"
        expected = BSV::Primitives::Digest.hmac_sha256(shared_secret.compressed, invoice.encode('UTF-8'))
        expect(decrypted).to eq(expected)
      end
    end
  end

  describe '#derive_revelation_keyring' do
    let(:certifier_key) { BSV::Primitives::PrivateKey.generate }
    let(:verifier_key) { BSV::Primitives::PrivateKey.generate }
    let(:verifier_hex) { verifier_key.public_key.to_hex }
    let(:certifier_hex) { certifier_key.public_key.to_hex }
    let(:cert_type) { 'test-cert-type' }
    let(:serial) { 'serial-001' }

    # Simulate a certifier creating an encrypted keyring for the subject.
    # BRC-52: certifier encrypts field keys using:
    #   protocol: [2, "authrite certificate field encryption {type}"]
    #   key_id: "{serial} {field_name}"
    #   counterparty: subject's public key
    let(:certifier_deriver) { described_class.new(private_key: certifier_key) }
    let(:field_key_name) { SecureRandom.random_bytes(32) }
    let(:field_key_email) { SecureRandom.random_bytes(32) }

    let(:keyring) do
      decrypt_protocol = [2, "authrite certificate field encryption #{cert_type}"]
      {
        'name' => certifier_deriver.encrypt(
          plaintext: field_key_name,
          protocol_id: decrypt_protocol,
          key_id: "#{serial} name",
          counterparty: deriver.identity_key
        ),
        'email' => certifier_deriver.encrypt(
          plaintext: field_key_email,
          protocol_id: decrypt_protocol,
          key_id: "#{serial} email",
          counterparty: deriver.identity_key
        )
      }
    end

    let(:certificate) do
      {
        type: cert_type,
        serial_number: serial,
        certifier: certifier_hex,
        subject: deriver.identity_key,
        keyring: keyring
      }
    end

    it 'returns empty hash for empty fields_to_reveal' do
      result = deriver.derive_revelation_keyring(
        certificate: certificate,
        fields_to_reveal: [],
        verifier: verifier_hex
      )
      expect(result).to eq({})
    end

    it 'returns empty hash for nil fields_to_reveal' do
      result = deriver.derive_revelation_keyring(
        certificate: certificate,
        fields_to_reveal: nil,
        verifier: verifier_hex
      )
      expect(result).to eq({})
    end

    it 'raises when certificate has no keyring' do
      cert_no_keyring = certificate.merge(keyring: nil)
      expect do
        deriver.derive_revelation_keyring(
          certificate: cert_no_keyring,
          fields_to_reveal: ['name'],
          verifier: verifier_hex
        )
      end.to raise_error(BSV::Wallet::Error, /no keyring/)
    end

    it 'raises when certificate has empty keyring' do
      cert_empty_keyring = certificate.merge(keyring: {})
      expect do
        deriver.derive_revelation_keyring(
          certificate: cert_empty_keyring,
          fields_to_reveal: ['name'],
          verifier: verifier_hex
        )
      end.to raise_error(BSV::Wallet::Error, /no keyring/)
    end

    it 'raises when a field is not in the keyring' do
      expect do
        deriver.derive_revelation_keyring(
          certificate: certificate,
          fields_to_reveal: ['nonexistent'],
          verifier: verifier_hex
        )
      end.to raise_error(BSV::Wallet::Error, /not found in certificate keyring/)
    end

    it 'returns a hash mapping field names to re-encrypted keys' do
      result = deriver.derive_revelation_keyring(
        certificate: certificate,
        fields_to_reveal: %w[name email],
        verifier: verifier_hex
      )
      expect(result).to be_a(Hash)
      expect(result.keys).to contain_exactly('name', 'email')
      expect(result['name']).to be_a(String)
      expect(result['email']).to be_a(String)
    end

    context 'round-trip: verifier can decrypt the re-encrypted keys' do
      it 'decrypts to the original field keys' do
        result = deriver.derive_revelation_keyring(
          certificate: certificate,
          fields_to_reveal: %w[name email],
          verifier: verifier_hex
        )

        verifier_deriver = described_class.new(private_key: verifier_key)
        encrypt_protocol = [2, 'authrite certificate field encryption']

        decrypted_name = verifier_deriver.decrypt(
          ciphertext: result['name'],
          protocol_id: encrypt_protocol,
          key_id: "#{serial} name",
          counterparty: deriver.identity_key
        )

        decrypted_email = verifier_deriver.decrypt(
          ciphertext: result['email'],
          protocol_id: encrypt_protocol,
          key_id: "#{serial} email",
          counterparty: deriver.identity_key
        )

        expect(decrypted_name).to eq(field_key_name)
        expect(decrypted_email).to eq(field_key_email)
      end
    end

    context 'with privileged: true' do
      it 'uses the privileged keyring' do
        priv_deriver = described_class.new(private_key: root_key, privileged_key: privileged_key)

        # Build keyring encrypted for the privileged key's identity
        decrypt_protocol = [2, "authrite certificate field encryption #{cert_type}"]
        priv_keyring = {
          'name' => certifier_deriver.encrypt(
            plaintext: field_key_name,
            protocol_id: decrypt_protocol,
            key_id: "#{serial} name",
            counterparty: privileged_key.public_key.to_hex
          )
        }
        priv_cert = certificate.merge(keyring: priv_keyring)

        result = priv_deriver.derive_revelation_keyring(
          certificate: priv_cert,
          fields_to_reveal: ['name'],
          verifier: verifier_hex,
          privileged: true
        )

        # Verifier should be able to decrypt using the privileged identity
        verifier_deriver = described_class.new(private_key: verifier_key)
        decrypted = verifier_deriver.decrypt(
          ciphertext: result['name'],
          protocol_id: [2, 'authrite certificate field encryption'],
          key_id: "#{serial} name",
          counterparty: privileged_key.public_key.to_hex
        )
        expect(decrypted).to eq(field_key_name)
      end
    end

    it 'reveals only the requested fields' do
      result = deriver.derive_revelation_keyring(
        certificate: certificate,
        fields_to_reveal: ['name'],
        verifier: verifier_hex
      )
      expect(result.keys).to eq(['name'])
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
