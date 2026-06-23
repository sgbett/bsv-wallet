# frozen_string_literal: true

module BSV
  module Wallet
    # BRC-42/43 key derivation facade.
    #
    # Wraps one or two root private keys (everyday + optional privileged)
    # and provides key derivation per the BRC-42 spec. Invoice numbers
    # follow the BRC-43 format: "{security_level}-{protocol_name}-{key_id}".
    #
    # @example
    #   kd = KeyDeriver.new(private_key: BSV::Primitives::PrivateKey.generate)
    #   kd.identity_key  #=> "02abc...def" (66-char hex)
    #   pub = kd.derive_public_key(protocol_id: [1, "my protocol"], key_id: "1", counterparty: "self")
    class KeyDeriver
      ANYONE_PRIVATE_KEY = BSV::Primitives::PrivateKey.new(OpenSSL::BN.new(1))
      ANYONE_PUBLIC_KEY = ANYONE_PRIVATE_KEY.public_key

      # Validate that +hex+ is a syntactically well-formed compressed
      # BRC-43 counterparty pubkey hex string (33-byte, +02+/+03+ prefix,
      # 66 hex chars total; case-tolerant). Class method — a pure regex
      # check with no instance state, hoisted out of the private
      # instance-method form so callers without a +KeyDeriver+ instance
      # (e.g. +Engine::Transmission+) can validate counterparties at the
      # engine boundary before any DB write.
      #
      # The +04+ uncompressed shape is **not** accepted — the regex's 64
      # trailing hex chars match only the compressed tail; an actual
      # uncompressed pubkey needs 128 trailing hex chars and so falls
      # through to the raise. The wallet has no caller that passes
      # uncompressed identity keys, and BRC-43 mandates compressed.
      # Callers that need stricter parity with the schema CHECK
      # (lowercase only) layer their own regex on top — see
      # +Engine::Transmission#validate_counterparty!+.
      #
      # @param hex [String]
      # @raise [BSV::Wallet::InvalidParameterError]
      def self.validate_counterparty_hex!(hex)
        return if hex.is_a?(String) && hex.match?(/\A(?:02|03)[0-9a-fA-F]{64}\z/)

        message = '"self", "anyone", or a 66-char compressed pubkey hex ' \
                  '(02/03 prefix); 04-uncompressed is not accepted'
        raise BSV::Wallet::InvalidParameterError.new('counterparty', message)
      end

      # Strict variant of +validate_counterparty_hex!+ — lowercase hex only,
      # mirroring the certificates pubkey-shape CHECK in migration 003
      # (subject/certifier/verifier) and Engine::Transmission's
      # BRC43_COMPRESSED_LOWERCASE constant. Use this when the value is
      # destined for a column that has a lowercase-only CHECK; the looser
      # counterparty variant accepts mixed-case for derivation use.
      #
      # @param hex [String]
      # @param param_name [String] field name for the error message
      # @raise [BSV::Wallet::InvalidParameterError]
      def self.validate_identity_pubkey_hex!(hex, param_name: 'identity_key')
        return if hex.is_a?(String) && hex.match?(/\A0[23][0-9a-f]{64}\z/)

        raise BSV::Wallet::InvalidParameterError.new(
          param_name,
          'lowercase-hex compressed pubkey (02|03 prefix + 64 hex chars; ' \
          'matches the certificates schema CHECK in db/migrations/003)'
        )
      end

      # @param private_key [BSV::Primitives::PrivateKey] everyday root key
      # @param privileged_key [BSV::Primitives::PrivateKey, nil] optional privileged root key
      def initialize(private_key:, privileged_key: nil)
        @root_key = private_key
        @privileged_key = privileged_key
      end

      # The root (everyday) private key, for signing UTXOs paid directly to the
      # identity address (no BRC-42/43 derivation).
      def root_private_key
        @root_key
      end

      # The 32-byte raw scalar of the root private key.
      # Used for HMAC computations (e.g., WBIKD recovery markers).
      def root_private_key_bytes
        @root_key.to_bytes
      end

      # Returns the compressed public key hex of the everyday key.
      #
      # This is the BRC-100 +getPublicKey+ emission value — the
      # *identity* key crosses BRC boundaries as hex by spec, so the
      # canonical accessor returns hex. Crypto-op consumers (hash160,
      # ECDH input bytes) should use +identity_key_bytes+ instead of
      # round-tripping this through +[hex].pack('H*')+.
      #
      # Derived pubkeys (+derive_public_key+) are returned as binary —
      # they don't cross a BRC boundary as themselves. See the
      # "Public Key Convention" section of CLAUDE.md for the full rule.
      #
      # @return [String] 66-character hex-encoded compressed public key
      def identity_key
        @identity_key ||= @root_key.public_key.to_hex
      end

      # Returns the compressed public key as 33 raw bytes — the binary
      # form for crypto-op consumers (hash160, ECDH input). Memoised
      # symmetrically with +identity_key+.
      #
      # @return [String] 33-byte binary string (compressed public key)
      def identity_key_bytes
        @identity_key_bytes ||= @root_key.public_key.compressed
      end

      # Derive a child public key using BRC-42.
      #
      # In normal mode (for_self: false), derives OUR child public key that
      # the counterparty could also compute if they knew our public key.
      # Equivalent to derive_private_key(...).public_key.
      #
      # In for_self mode, derives the COUNTERPARTY'S child public key —
      # the key they would have derived using their private key and our
      # public key.
      #
      # @param protocol_id [Array<Integer, String>] [security_level, protocol_name]
      # @param key_id [String] key identifier
      # @param counterparty [String] "self", "anyone", or hex public key
      # @param for_self [Boolean] reverse derivation direction
      # @param privileged [Boolean] use privileged keyring
      # @return [String] compressed public key bytes (33 bytes, binary)
      def derive_public_key(protocol_id:, key_id:, counterparty:, for_self: false, privileged: false)
        key = select_key(privileged)
        invoice = compute_invoice_number(protocol_id, key_id)
        counterparty_pub = resolve_counterparty(counterparty)

        if for_self
          # Counterparty's child public key, derived using our private key
          counterparty_pub.derive_child(key, invoice).compressed
        else
          # Our child public key — same as derive_private_key.public_key
          key.derive_child(counterparty_pub, invoice).public_key.compressed
        end
      end

      # Derive a child private key using BRC-42.
      #
      # @param protocol_id [Array<Integer, String>] [security_level, protocol_name]
      # @param key_id [String] key identifier
      # @param counterparty [String] "self", "anyone", or hex public key
      # @param privileged [Boolean] use privileged keyring
      # @return [BSV::Primitives::PrivateKey] derived child private key
      def derive_private_key(protocol_id:, key_id:, counterparty:, privileged: false)
        key = select_key(privileged)
        invoice = compute_invoice_number(protocol_id, key_id)
        counterparty_pub = resolve_counterparty(counterparty)

        key.derive_child(counterparty_pub, invoice)
      end

      # Encrypt plaintext using AES-256-GCM with an ECDH-derived symmetric key.
      #
      # Derives child keys for both parties, computes the ECDH shared secret,
      # and encrypts using AES-256-GCM.
      #
      # @param plaintext [String] binary data to encrypt
      # @param protocol_id [Array<Integer, String>] [security_level, protocol_name]
      # @param key_id [String] key identifier
      # @param counterparty [String] "self", "anyone", or hex public key
      # @param privileged [Boolean] use privileged keyring
      # @return [String] binary ciphertext (IV + ciphertext + auth tag)
      def encrypt(plaintext:, protocol_id:, key_id:, counterparty:, privileged: false)
        sym_key = derive_symmetric_key(
          protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty, privileged: privileged
        )
        sym_key.encrypt(plaintext)
      end

      # Decrypt ciphertext using AES-256-GCM with an ECDH-derived symmetric key.
      #
      # Derives the same symmetric key used for encryption and decrypts.
      #
      # @param ciphertext [String] binary data to decrypt (IV + ciphertext + auth tag)
      # @param protocol_id [Array<Integer, String>] [security_level, protocol_name]
      # @param key_id [String] key identifier
      # @param counterparty [String] "self", "anyone", or hex public key
      # @param privileged [Boolean] use privileged keyring
      # @return [String] decrypted binary plaintext
      # @raise [OpenSSL::Cipher::CipherError] if authentication fails
      def decrypt(ciphertext:, protocol_id:, key_id:, counterparty:, privileged: false)
        sym_key = derive_symmetric_key(
          protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty, privileged: privileged
        )
        sym_key.decrypt(ciphertext)
      end

      # Compute an HMAC-SHA-256 over data using an ECDH-derived symmetric key.
      #
      # Derives the symmetric key for the given derivation parameters and
      # returns the HMAC-SHA-256 of the data keyed with that symmetric key.
      #
      # @param data [String] binary data to authenticate
      # @param protocol_id [Array<Integer, String>] [security_level, protocol_name]
      # @param key_id [String] key identifier
      # @param counterparty [String] "self", "anyone", or hex public key
      # @param privileged [Boolean] use privileged keyring
      # @return [String] 32-byte HMAC
      def create_hmac(data:, protocol_id:, key_id:, counterparty:, privileged: false)
        sym_key = derive_symmetric_key(
          protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty, privileged: privileged
        )
        BSV::Primitives::Digest.hmac_sha256(sym_key.to_bytes, data)
      end

      # Derive a revelation keyring for a verifier from a certificate's master keyring.
      #
      # For each field in +fields_to_reveal+, decrypts the encrypted field key from the
      # certificate's keyring (using the certifier as counterparty per BRC-52), then
      # re-encrypts it for the specified verifier.
      #
      # @param certificate [Hash] certificate hash with :type, :serial_number, :certifier, :keyring
      # @param fields_to_reveal [Array<String>] field names whose keys to reveal
      # @param verifier [String] verifier's public key (hex string)
      # @param privileged [Boolean] use privileged keyring
      # @return [Hash{String => String}] field names mapped to re-encrypted keys
      # @raise [BSV::Wallet::Error] if a field is not in the keyring or keyring is missing
      def derive_revelation_keyring(certificate:, fields_to_reveal:, verifier:, privileged: false)
        return {} if fields_to_reveal.nil? || fields_to_reveal.empty?

        keyring = certificate[:keyring]
        raise BSV::Wallet::Error, 'certificate has no keyring' if keyring.nil? || keyring.empty?

        cert_type = certificate[:type]
        serial = certificate[:serial_number]
        certifier = certificate[:certifier]

        # BRC-52: master keyring was encrypted with protocol "authrite certificate field encryption {type}"
        decrypt_protocol = [2, "authrite certificate field encryption #{cert_type}"]

        # BRC-52: revelation keyring uses protocol "authrite certificate field encryption"
        encrypt_protocol = [2, 'authrite certificate field encryption']

        verifier_hex = normalize_pubkey_to_hex(verifier)

        fields_to_reveal.each_with_object({}) do |field_name, result|
          field_key_name = field_name.to_s
          encrypted_key = keyring[field_key_name]

          unless encrypted_key
            raise BSV::Wallet::Error,
                  "field '#{field_key_name}' not found in certificate keyring"
          end

          key_id = "#{serial} #{field_key_name}"

          # Decrypt the field key (certifier encrypted it for us)
          field_key = decrypt(
            ciphertext: encrypted_key,
            protocol_id: decrypt_protocol,
            key_id: key_id,
            counterparty: certifier,
            privileged: privileged
          )

          # Re-encrypt the field key for the verifier
          result[field_key_name] = encrypt(
            plaintext: field_key,
            protocol_id: encrypt_protocol,
            key_id: key_id,
            counterparty: verifier_hex,
            privileged: privileged
          )
        end
      end

      # Sign data using ECDSA with a derived private key.
      #
      # Either +data+ or +hash_to_directly_sign+ must be provided.
      # When +data+ is given, it is SHA-256 hashed before signing.
      # When +hash_to_directly_sign+ is given, it is used as-is (must be 32 bytes).
      #
      # @param data [String, nil] raw data to hash and sign
      # @param hash_to_directly_sign [String, nil] pre-computed 32-byte hash to sign directly
      # @param protocol_id [Array<Integer, String>] [security_level, protocol_name]
      # @param key_id [String] key identifier
      # @param counterparty [String] "self", "anyone", or hex public key
      # @param privileged [Boolean] use privileged keyring
      # @return [BSV::Primitives::Signature] the ECDSA signature
      def create_signature(protocol_id:, key_id:, counterparty:, data: nil, hash_to_directly_sign: nil,
                           privileged: false)
        hash = resolve_hash(data, hash_to_directly_sign)
        private_key = derive_private_key(protocol_id: protocol_id, key_id: key_id,
                                         counterparty: counterparty, privileged: privileged)
        private_key.sign(hash)
      end

      # Verify an ECDSA signature against data using a derived public key.
      #
      # Either +data+ or +hash_to_directly_verify+ must be provided.
      # When +data+ is given, it is SHA-256 hashed before verification.
      #
      # @param signature [BSV::Primitives::Signature] the signature to verify
      # @param data [String, nil] raw data that was signed
      # @param hash_to_directly_verify [String, nil] pre-computed 32-byte hash
      # @param protocol_id [Array<Integer, String>] [security_level, protocol_name]
      # @param key_id [String] key identifier
      # @param counterparty [String] "self", "anyone", or hex public key
      # @param for_self [Boolean] reverse derivation direction for verification
      # @param privileged [Boolean] use privileged keyring
      # @return [Boolean] true if the signature is valid
      def verify_signature(signature:, protocol_id:, key_id:, counterparty:, data: nil, hash_to_directly_verify: nil,
                           for_self: false, privileged: false)
        hash = resolve_hash(data, hash_to_directly_verify)
        pub_bytes = derive_public_key(protocol_id: protocol_id, key_id: key_id,
                                      counterparty: counterparty, for_self: for_self,
                                      privileged: privileged)
        public_key = BSV::Primitives::PublicKey.from_bytes(pub_bytes)
        public_key.verify(hash, signature)
      end

      # Reveal the ECDH shared secret between this wallet and a counterparty,
      # encrypted for a verifier with a Schnorr proof (BRC-69 Method 1).
      #
      # @param counterparty [String] hex public key (not 'self' or 'anyone')
      # @param verifier [String] hex public key of the verifier
      # @param privileged [Boolean] use privileged keyring
      # @return [Hash] revelation result with encrypted linkage and proof
      def reveal_counterparty_linkage(counterparty:, verifier:, privileged: false)
        validate_linkage_counterparty!(counterparty)
        key = select_key(privileged)
        counterparty_pub = resolve_counterparty(counterparty)

        # Compute the ECDH shared secret (the linkage being revealed)
        shared_secret = key.derive_shared_secret(counterparty_pub)
        linkage = shared_secret.compressed

        revelation_time = Time.now.utc.iso8601

        # Encrypt the linkage for the verifier
        encrypted_linkage = encrypt(
          plaintext: linkage,
          protocol_id: [2, 'counterparty linkage revelation'],
          key_id: revelation_time,
          counterparty: verifier,
          privileged: privileged
        )

        # Generate Schnorr proof of the shared secret
        proof = BSV::Primitives::Schnorr.generate_proof(
          key, key.public_key, counterparty_pub, shared_secret
        )

        # Serialize the proof: R (33 bytes) + S' (33 bytes) + z (32 bytes, zero-padded)
        z_bytes = proof.z.to_s(2)
        z_bytes = ("\x00".b * (32 - z_bytes.length)) + z_bytes if z_bytes.length < 32
        proof_bin = proof.r.compressed + proof.s_prime.compressed + z_bytes

        # Encrypt the proof for the verifier
        encrypted_proof = encrypt(
          plaintext: proof_bin,
          protocol_id: [2, 'counterparty linkage revelation'],
          key_id: revelation_time,
          counterparty: verifier,
          privileged: privileged
        )

        {
          prover: identity_key,
          verifier: verifier,
          counterparty: counterparty,
          revelation_time: revelation_time,
          encrypted_linkage: encrypted_linkage,
          encrypted_linkage_proof: encrypted_proof
        }
      end

      # Reveal the specific key offset for a particular derived key,
      # encrypted for a verifier (BRC-69 Method 2).
      #
      # @param counterparty [String] hex public key (not 'self' or 'anyone')
      # @param verifier [String] hex public key of the verifier
      # @param protocol_id [Array<Integer, String>] [security_level, protocol_name]
      # @param key_id [String] key identifier
      # @param privileged [Boolean] use privileged keyring
      # @return [Hash] revelation result with encrypted linkage and proof_type 0
      def reveal_specific_linkage(counterparty:, verifier:, protocol_id:, key_id:, privileged: false)
        validate_linkage_counterparty!(counterparty)
        key = select_key(privileged)
        counterparty_pub = resolve_counterparty(counterparty)

        # Compute the specific key offset (HMAC of shared secret with invoice number)
        shared_secret = key.derive_shared_secret(counterparty_pub)
        invoice = compute_invoice_number(protocol_id, key_id)
        linkage = BSV::Primitives::Digest.hmac_sha256(shared_secret.compressed, invoice.encode('UTF-8'))

        derived_protocol = "specific linkage revelation #{protocol_id[0]} #{protocol_id[1]}"

        # Encrypt the linkage for the verifier
        encrypted_linkage = encrypt(
          plaintext: linkage,
          protocol_id: [2, derived_protocol],
          key_id: key_id,
          counterparty: verifier,
          privileged: privileged
        )

        # Encrypt proof_type 0 for the verifier
        encrypted_proof = encrypt(
          plaintext: "\x00".b,
          protocol_id: [2, derived_protocol],
          key_id: key_id,
          counterparty: verifier,
          privileged: privileged
        )

        {
          prover: identity_key,
          verifier: verifier,
          counterparty: counterparty,
          protocol_id: protocol_id,
          key_id: key_id,
          encrypted_linkage: encrypted_linkage,
          encrypted_linkage_proof: encrypted_proof,
          proof_type: 0
        }
      end

      private

      # Validate that a counterparty is valid for linkage revelation.
      # 'self' and 'anyone' are not allowed.
      def validate_linkage_counterparty!(counterparty)
        raise BSV::Wallet::Error, 'cannot reveal linkage with yourself' if counterparty == 'self'

        return unless counterparty == 'anyone'

        raise BSV::Wallet::Error, 'cannot reveal linkage with "anyone"'
      end

      # Resolve data or a pre-computed hash into a 32-byte digest for signing/verification.
      #
      # @param data [String, nil] raw data to SHA-256 hash
      # @param direct_hash [String, nil] pre-computed 32-byte hash
      # @return [String] 32-byte hash
      def resolve_hash(data, direct_hash)
        if direct_hash
          direct_hash
        elsif data
          BSV::Primitives::Digest.sha256(data)
        else
          raise BSV::Wallet::Error, 'either data or a pre-computed hash must be provided'
        end
      end

      # Derive a symmetric key via ECDH between child keys.
      #
      # Derives our child private key and the counterparty's child public key,
      # then computes the ECDH shared secret to produce an AES-256-GCM key.
      #
      # @param protocol_id [Array<Integer, String>] [security_level, protocol_name]
      # @param key_id [String] key identifier
      # @param counterparty [String] "self", "anyone", or hex public key
      # @param privileged [Boolean] use privileged keyring
      # @return [BSV::Primitives::SymmetricKey]
      def derive_symmetric_key(protocol_id:, key_id:, counterparty:, privileged: false)
        key = select_key(privileged)
        invoice = compute_invoice_number(protocol_id, key_id)
        counterparty_pub = resolve_counterparty(counterparty)

        child_priv = key.derive_child(counterparty_pub, invoice)
        child_pub = counterparty_pub.derive_child(key, invoice)

        BSV::Primitives::SymmetricKey.from_ecdh(child_priv, child_pub)
      end

      # Format a BRC-43 invoice number from protocol_id and key_id.
      #
      # @param protocol_id [Array<Integer, String>] [security_level, protocol_name]
      # @param key_id [String] key identifier
      # @return [String] formatted invoice number
      def compute_invoice_number(protocol_id, key_id)
        security_level, protocol_name = protocol_id

        validate_security_level!(security_level)
        validate_protocol_name!(protocol_name)
        validate_key_id!(key_id)

        "#{security_level}-#{protocol_name}-#{key_id}"
      end

      # Resolve a counterparty string to a PublicKey.
      #
      # @param counterparty [String] "self", "anyone", or hex public key
      # @return [BSV::Primitives::PublicKey]
      def resolve_counterparty(counterparty)
        case counterparty
        when 'self'
          @root_key.public_key
        when 'anyone'
          ANYONE_PUBLIC_KEY
        else
          self.class.validate_counterparty_hex!(counterparty)
          BSV::Primitives::PublicKey.from_hex(counterparty)
        end
      end

      # Select the appropriate root key based on privileged flag.
      #
      # @param privileged [Boolean]
      # @return [BSV::Primitives::PrivateKey]
      def select_key(privileged)
        if privileged
          raise BSV::Wallet::Error, 'privileged key required but not configured' unless @privileged_key

          @privileged_key
        else
          @root_key
        end
      end

      def validate_security_level!(level)
        return if level.is_a?(Integer) && level >= 0 && level <= 2

        raise BSV::Wallet::InvalidParameterError.new('security level', 'an integer between 0 and 2')
      end

      def validate_protocol_name!(name)
        unless name.is_a?(String) && name.length >= 5 && name.length <= 400
          raise BSV::Wallet::InvalidParameterError.new('protocol name', 'a string between 5 and 400 characters')
        end

        raise BSV::Wallet::InvalidParameterError.new('protocol name', 'free of consecutive spaces') if name.include?('  ')

        return unless name.downcase.end_with?(' protocol')

        raise BSV::Wallet::InvalidParameterError.new('protocol name', 'not ending with " protocol"')
      end

      def validate_key_id!(key_id)
        raise BSV::Wallet::InvalidParameterError.new('key_id', 'a non-empty string') if key_id.nil? || (key_id.is_a?(String) && key_id.empty?)

        return unless key_id.is_a?(String) && key_id.length > 800

        raise BSV::Wallet::InvalidParameterError.new('key_id', 'no longer than 800 characters')
      end

      # Normalize a public key to hex string, accepting either hex or binary.
      def normalize_pubkey_to_hex(key)
        if key.is_a?(String) && key.match?(/\A(?:02|03)[0-9a-fA-F]{64}\z/)
          key
        elsif key.is_a?(String) && key.bytesize == 33
          key.unpack1('H*')
        else
          key
        end
      end
    end
  end
end
