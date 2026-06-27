# frozen_string_literal: true

module BSV
  module Wallet
    module CLI
      # Defence against accidental secrets disclosure on CLI output paths.
      #
      # Four lines of defence:
      #   1. +Secrets.redact(obj)+ — deep-walks Hash/Array structures and
      #      elides values whose keys match the sensitive-field pattern.
      #      Used by +Commands::Base#emit_json+ before stdout writes.
      #   2. +Dispatcher#redact_message+ — applies the same field pattern
      #      at the STRING level (regex substitution) to exception
      #      messages bubbled to stderr by the top-level rescue.
      #      OptionParser / engine errors quote argv tokens verbatim;
      #      this stops a stray +--wif=<wif>+ value reaching stderr.
      #   3. +KeyDeriver#inspect+ — overridden to elide +@root_key+.
      #      Defends against a stray +Engine.inspect+ in an exception
      #      message or a future +#to_s+ slip.
      #   4. +Engine#inspect+ — overridden to elide +@key_deriver+ and
      #      +@store+. Same rationale; Engine holds the keyderiver as an
      #      ivar so an unredacted inspect would expose root material.
      #
      # The redaction is conservative: anything that LOOKS like a key
      # field name is replaced with +"[REDACTED]"+. Pubkey/identity-key
      # fields are NOT redacted — those are interchange identifiers, not
      # secrets, per the identity-key hex carve-out.
      module Secrets
        # Explicit allowlist of sensitive field names. Catch-all
        # wildcards over +*_key+ would snag compound identifiers like
        # +sender_identity_key+ / +recipient_public_key+ that ARE
        # interchange identifiers, not secrets (per the identity-key
        # hex carve-out). Better to enumerate known-secret names and
        # leave compound pubkey-shaped names alone.
        #
        # Members:
        #   - +wif+ — WIF private key
        #   - +secret+ — generic secret material
        #   - +private_key+ / +signing_key+ / +root_key+ — named keys
        #   - +derivation_prefix+ / +derivation_suffix+ — per-output
        #     BRC-29 derivation hints (recoverable from the chain but
        #     should not leak through error messages)
        #
        # The single canonical pattern string below is the source of
        # truth for SENSITIVE_FIELD (full-string match for JSON keys),
        # and for the string-level regexes in +Dispatcher+ and
        # +Commands::Base+ which interpolate it into token-shape
        # context (+\b … [=:]\s* \S++). Keep the three in sync via this
        # constant; do not edit the regexes independently.
        SENSITIVE_FIELD_NAMES_PATTERN =
          '(?:wif|secret|private_key|signing_key|root_key|derivation_(?:prefix|suffix))'

        SENSITIVE_FIELD = /\A#{SENSITIVE_FIELD_NAMES_PATTERN}\z/i

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
