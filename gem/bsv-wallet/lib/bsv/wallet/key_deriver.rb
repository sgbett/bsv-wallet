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

      # @param private_key [BSV::Primitives::PrivateKey] everyday root key
      # @param privileged_key [BSV::Primitives::PrivateKey, nil] optional privileged root key
      def initialize(private_key:, privileged_key: nil)
        @root_key = private_key
        @privileged_key = privileged_key
      end

      # Returns the compressed public key hex of the everyday key.
      #
      # @return [String] 66-character hex-encoded compressed public key
      def identity_key
        @identity_key ||= @root_key.public_key.to_hex
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

      private

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
          validate_counterparty_hex!(counterparty)
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

        if name.include?('  ')
          raise BSV::Wallet::InvalidParameterError.new('protocol name', 'free of consecutive spaces')
        end

        return unless name.downcase.end_with?(' protocol')

        raise BSV::Wallet::InvalidParameterError.new('protocol name', 'not ending with " protocol"')
      end

      def validate_key_id!(key_id)
        if key_id.nil? || (key_id.is_a?(String) && key_id.empty?)
          raise BSV::Wallet::InvalidParameterError.new('key_id', 'a non-empty string')
        end

        return unless key_id.is_a?(String) && key_id.length > 800

        raise BSV::Wallet::InvalidParameterError.new('key_id', 'no longer than 800 characters')
      end

      def validate_counterparty_hex!(hex)
        return if hex.is_a?(String) && hex.match?(/\A(?:02|03|04)[0-9a-fA-F]{64}\z/)

        raise BSV::Wallet::InvalidParameterError.new('counterparty',
                                                     '"self", "anyone", or a valid hex public key')
      end
    end
  end
end
