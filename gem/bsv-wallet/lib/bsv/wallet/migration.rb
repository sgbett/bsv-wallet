# frozen_string_literal: true

module BSV
  module Wallet
    # Migration-time wallet context.
    #
    # The per-wallet +outputs.spendable_recoverable+ CHECK (HLR #467) embeds
    # the WIF-derived root P2PKH script as a binary literal — the constraint
    # has to know the wallet's identity at +CREATE TABLE+ time. Sequel
    # migrations don't take parameters, so this module exposes a global
    # accessor that +Store#migrate!+ populates before the migrator runs and
    # resets in its +ensure+ block.
    #
    # The literal is built via +BSV::Script::Script.p2pkh_lock(hash).to_binary+
    # (single source of truth, SDK). Never hand-roll the
    # +\x76\xa9\x14...\x88\xac+ byte sequence.
    #
    # Lifecycle (per wallet boot):
    #
    #   1. CLI constructs +KeyDeriver+ → has +identity_pubkey_hash+.
    #   2. CLI constructs +Store.new(identity_pubkey_hash: kd.identity_pubkey_hash, ...)+.
    #   3. +Store#migrate!+ stashes the hash on +Migration.identity_pubkey_hash+,
    #      runs +Sequel::Migrator+ (CHECK expressions read +expected_root_script+),
    #      and nils the accessor in its +ensure+.
    #
    # See +docs/reference/intent-and-outcomes.md+ and HLR #467 for the
    # principle (intent stated explicitly; outcomes persisted as rows).
    module Migration
      class << self
        attr_accessor :identity_pubkey_hash
      end

      # The wallet's root P2PKH locking script bytes, derived from the
      # currently-set +identity_pubkey_hash+. Raises if no hash is set —
      # the migrator must populate the global before invoking any
      # migration that reads this helper.
      #
      # @return [String] 25-byte binary P2PKH locking script
      # @raise [RuntimeError] when +identity_pubkey_hash+ is unset
      def self.expected_root_script
        unless identity_pubkey_hash
          raise 'BSV::Wallet::Migration.identity_pubkey_hash not set — ' \
                'Store#migrate! must populate before any migration runs'
        end

        BSV::Script::Script.p2pkh_lock(identity_pubkey_hash).to_binary
      end
    end
  end
end
