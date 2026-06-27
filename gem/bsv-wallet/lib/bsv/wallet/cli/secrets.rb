# frozen_string_literal: true

module BSV
  module Wallet
    module CLI
      # Defence against accidental secrets disclosure on CLI output paths.
      #
      # Three lines of defence:
      #   1. +Secrets.redact(obj)+ — deep-walks Hash/Array structures and
      #      elides values whose keys match the sensitive-field pattern.
      #      Used by +Commands::Base#emit_json+ before stdout writes and
      #      by the dispatcher's top-level rescue before stderr writes.
      #   2. +KeyDeriver#inspect+ — overridden to elide +@root_key+.
      #      Defends against a stray +Engine.inspect+ in an exception
      #      message or a future +#to_s+ slip.
      #   3. +Engine#inspect+ — overridden to elide +@key_deriver+ and
      #      +@store+. Same rationale; Engine holds the keyderiver as an
      #      ivar so an unredacted inspect would expose root material.
      #
      # The redaction is conservative: anything that LOOKS like a key
      # field name is replaced with +"[REDACTED]"+. Pubkey/identity-key
      # fields are NOT redacted — those are interchange identifiers, not
      # secrets, per the identity-key hex carve-out.
      module Secrets
        # Field-name pattern (case-insensitive). Matches:
        #   - +wif+, +Wif+, +WIF+
        #   - +secret+, +Secret+
        #   - anything ending in +_key+ (matches +root_key+, +private_key+,
        #     +signing_key+) EXCEPT +identity_key+ + +public_key+ +
        #     +pubkey+ (interchange identifiers, not secret material).
        #   - +derivation_prefix+ / +derivation_suffix+ (per-output BRC-29
        #     derivation hints — recoverable from the chain but should
        #     not leak through error messages).
        SENSITIVE_FIELD = /
          \A(
            wif |
            secret |
            (?!identity_|public_|pub)\w*_(key|priv) |
            (private|signing|root)_key |
            derivation_(prefix|suffix)
          )\z
        /xi

        REDACTED = '[REDACTED]'

        module_function

        # Deep-walk +obj+; return a copy with sensitive fields elided.
        #
        # Hashes: keys matching +SENSITIVE_FIELD+ have their values
        # replaced with +REDACTED+. Nested hashes/arrays recurse.
        #
        # Arrays: each element recursed.
        #
        # Strings: returned unchanged (they're values, not field names).
        # Anything else (Integer, nil, Symbol, etc.): returned unchanged.
        #
        # Idempotent: +redact(redact(x)) == redact(x)+.
        #
        # @param obj [Object]
        # @return [Object] same shape as input with sensitive values elided
        def redact(obj)
          case obj
          when Hash
            obj.each_with_object({}) do |(k, v), out|
              out[k] = sensitive_key?(k) ? REDACTED : redact(v)
            end
          when Array
            obj.map { |element| redact(element) }
          else
            obj
          end
        end

        # @return [Boolean]
        def sensitive_key?(key)
          key.to_s.match?(SENSITIVE_FIELD)
        end
      end
    end
  end
end

# +#inspect+ overrides on key-bearing classes live in
# +cli/inspect_overrides.rb+ — required by the dispatcher alongside
# this file. Splitting them out keeps +Style/OneClassPerFile+ honest
# (this file is the +Secrets+ module; that file is the reopens).
