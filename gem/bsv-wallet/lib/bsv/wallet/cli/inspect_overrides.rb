# frozen_string_literal: true

# +#inspect+ overrides on classes carrying secret material. Required by
# +cli/dispatcher.rb+ so the protection is guaranteed any time the CLI
# is in play. The override is harmless for non-CLI callers — it changes
# how +inspect+ renders, not the underlying state.
#
# Background: Ruby's default +Object#inspect+ dumps ivars verbatim. For
# +KeyDeriver+ that means leaking +@root_key+; for +Engine+ that means
# leaking +@key_deriver+ (which in turn leaks +@root_key+). Custom
# +inspect+ methods elide both. See +Secrets on the CLI+ in the plan.
#
# This file deliberately reopens two existing classes (KeyDeriver +
# Engine) to add ONLY the +#inspect+ override. Grouping the overrides
# in one file makes their joint purpose (secrets redaction) visible
# at a glance. Splitting them across two files for the cop's benefit
# would scatter the security-relevant overrides.

module BSV
  module Wallet
    class KeyDeriver
      # Elide +@root_key+ from inspect output. The identity key is the
      # only field surfaced — that's an interchange identifier, not a
      # secret, per the pubkey-hex carve-out.
      def inspect
        "#<BSV::Wallet::KeyDeriver identity_key=#{identity_key.inspect}>"
      end
    end

    class Engine
      # Elide +@key_deriver+ and +@store+ from inspect output. Same
      # rationale as +KeyDeriver+: engine ivars include the keyderiver,
      # so an unredacted dump would expose root material via that path.
      def inspect
        '#<BSV::Wallet::Engine>'
      end
    end
  end
end
