# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        # The existence of a promotions row means "this action's outputs are
        # canonical" — the per-action fact that replaces the old
        # outputs.promoted flag (#307, ADR-022 / ADR-023). Keyed by action_id
        # (a non-auto PK that is also an FK to actions). Gating constraints
        # live in the schema: intent tracks the action, authorising_status
        # names the broadcast status that authorised a send-path promotion.
        class Promotion < Sequel::Model(:promotions)
          unrestrict_primary_key # action_id is set explicitly, not generated

          many_to_one :action, class: 'BSV::Wallet::Store::Models::Action'
        end
      end
    end
  end
end
