# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class Output < Sequel::Model
          # No timestamps plugin — outputs are immutable.
          # created_at is set by the database default.

          # The wallet's WIF-derived root P2PKH locking script bytes,
          # populated by +Store#migrate!+ from
          # +BSV::Wallet::Migration.expected_root_script+ (HLR #467).
          # Application-layer mirror of the per-wallet DB CHECK literal;
          # lets the model spot invalid combinations before the DB rejects.
          class << self
            attr_accessor :expected_root_script
          end

          many_to_one  :action, class: 'BSV::Wallet::Store::Models::Action'
          one_to_one   :spendable_entry, class: 'BSV::Wallet::Store::Models::Spendable', key: :output_id
          one_to_one   :detail, class: 'BSV::Wallet::Store::Models::OutputDetail', key: :output_id
          one_to_one   :input, class: 'BSV::Wallet::Store::Models::Input', key: :output_id
          one_to_one   :output_basket, class: 'BSV::Wallet::Store::Models::OutputBasket', key: :output_id
          many_to_many :tags, class: 'BSV::Wallet::Store::Models::Tag',
                              join_table: :output_tags,
                              left_key: :output_id, right_key: :tag_id

          dataset_module do
            # The UTXO set: outputs in the spendable table and not claimed by any input.
            def spendable
              spendable_ds = BSV::Wallet::Store::Models::Spendable.dataset
                                                                  .where(output_id: Sequel[:outputs][:id]).select(1)
              input_ds = BSV::Wallet::Store::Models::Input.dataset
                                                          .where(output_id: Sequel[:outputs][:id]).select(1)

              where(spendable_ds.exists).exclude(input_ds.exists)
            end

            # Filter outputs by basket membership. Every accepted value
            # applies a real filter — to apply *no* basket filter, omit
            # the call entirely and chain off +#spendable+ directly.
            #
            # - +nil+              → outputs with no +output_baskets+ row (unbasketed).
            # - +String+           → outputs in the named basket.
            # - +Array<String>+    → outputs in any of the named baskets.
            def in_basket(name_or_names)
              if name_or_names.nil?
                basket_ds = BSV::Wallet::Store::Models::OutputBasket.dataset
                                                                    .where(Sequel[:output_baskets][:output_id] => Sequel[:outputs][:id])
                                                                    .select(1)
                exclude(basket_ds.exists)
              else
                names = Array(name_or_names)
                basket_ds = BSV::Wallet::Store::Models::OutputBasket.dataset
                                                                    .join(:baskets, id: :basket_id)
                                                                    .where(Sequel[:output_baskets][:output_id] => Sequel[:outputs][:id])
                                                                    .where(Sequel[:baskets][:name] => names)
                                                                    .select(1)
                where(basket_ds.exists)
              end
            end

            # Filter outputs with at least the given satoshi value.
            def min_satoshis(value)
              where { satoshis >= value }
            end
          end

          def spendable?
            !spendable_entry.nil? && input.nil?
          end

          def basket
            output_basket&.basket
          end

          # Application-layer mirror of the +outputs+ table's two structural
          # CHECKs (+controls_all_or_nothing+ and +spendable_recoverable+,
          # HLR #467 / +intent-and-outcomes.md+). The DB enforces the same
          # rules — these validators surface failures as field-level errors
          # before the DB rejects, so callers see clean app-level messages
          # rather than raw +CheckConstraintViolation+ noise.
          #
          # Sequel calls +#save+ which raises +Sequel::ValidationFailed+
          # when +errors+ is non-empty; +Store+ wraps that and re-raises as
          # +BSV::Wallet::InvalidParameterError+ at the insertion boundary.
          def validate
            super
            validate_controls_all_or_nothing
            validate_spendable_recoverable
          end

          private

          # Mirror of the +controls_all_or_nothing+ CHECK. The derivation
          # triple (+derivation_prefix+/+derivation_suffix+/+sender_identity_key+)
          # must be all set or all absent — a partial fill is a structural
          # nonsense (no derivable spending key, no honest "outbound" claim).
          def validate_controls_all_or_nothing
            set_count = [derivation_prefix, derivation_suffix, sender_identity_key].count { |v| !v.nil? }
            return if [0, 3].include?(set_count)

            errors.add(:derivation_prefix,
                       'derivation_prefix/derivation_suffix/sender_identity_key must be all set or all absent ' \
                       '(HLR #467 / intent-and-outcomes.md)')
          end

          # Mirror of the +spendable_recoverable+ CHECK. Three independent
          # row properties (+root_pattern+ from +locking_script+ vs the
          # per-wallet expected root, +controls_set+ from the derivation
          # triple, and +spendable_intent+) yield 8 combinations; only
          # four are valid:
          #
          #   * root + no controls + spendable      — wallet-owned root P2PKH
          #   * non-root + no controls + none       — outbound (no recoverable key)
          #   * non-root + controls + spendable     — BRC-42 self-payment / change
          #   * non-root + controls + none          — BRC-29 outbound to counterparty
          #
          # Flat conditional matches the four valid permutations; anything
          # else fails. No +case/in+ — the codebase has no precedent for
          # pattern matching and a flat predicate is more searchable.
          def validate_spendable_recoverable
            # Pre-check: model can't validate without the wallet's expected
            # root script. Without this guard, +root_match+ would silently
            # be +false+ for every output (any value vs nil never matches),
            # so a legitimate root P2PKH output would fail the structural
            # check with a misleading "invalid combination" message.
            unless self.class.expected_root_script
              errors.add(:spendable_intent,
                         'Output.expected_root_script not configured — ' \
                         'Store.new(identity_pubkey_hash:) must run before ' \
                         'Output validation (HLR #467 / intent-and-outcomes.md)')
              return
            end

            intent = spendable_intent.to_s
            # Pre-check: +spendable_intent+ must be a recognised enum value.
            # Without this, the third disjunct below (+!root_match && controls_set+)
            # would accept any intent value — including +nil+ or garbage —
            # punting the failure to the DB's NOT NULL / ENUM rejection
            # (opaque +Sequel::NotNullConstraintViolation+) rather than a
            # clean field-level message at the model boundary.
            unless %w[spendable none].include?(intent)
              errors.add(:spendable_intent,
                         "must be one of: spendable, none (got #{intent.inspect}) " \
                         '(HLR #467 / intent-and-outcomes.md)')
              return
            end

            root_match   = locking_script == self.class.expected_root_script
            controls_set = !derivation_prefix.nil?

            valid =
              (root_match  && !controls_set && intent == 'spendable') ||
              (!root_match && !controls_set && intent == 'none')      ||
              (!root_match && controls_set)
            return if valid

            errors.add(:spendable_intent,
                       'invalid combination (HLR #467 / intent-and-outcomes.md): ' \
                       "root_match=#{root_match} controls=#{controls_set} intent=#{intent}")
          end
        end
      end
    end
  end
end
