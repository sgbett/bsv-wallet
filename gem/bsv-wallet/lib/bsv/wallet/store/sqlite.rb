# frozen_string_literal: true

module BSV
  module Wallet
    module Store
      # Default SQLite implementation of Interface::Store.
      #
      # Orchestration logic lives in Store::Base; this class supplies the
      # SQLite-specific adapter primitives:
      #
      #   - models           — the namespace of connection-bound model classes
      #   - try_lock_input   — input-claim detection (SQLite's insert_conflict
      #                        returns the rowid even on DO NOTHING, so we
      #                        re-query to detect ownership)
      class SQLite
        include BSV::Wallet::Interface::Store
        include BSV::Wallet::Store::Base

        def self.models
          BSV::Wallet::Store
        end

        def initialize(db: nil)
          @db = db || Connection.db
        end

        private

        # SQLite's insert_conflict returns last_insert_rowid even when
        # DO NOTHING fires, so we can't trust the return value. Re-query
        # to confirm this action owns the input row.
        def try_lock_input(record_id:, inp:)
          @db[:inputs].insert_conflict(target: :output_id).insert(
            action_id: record_id,
            output_id: inp[:output_id],
            vin: inp[:vin],
            nsequence: inp[:nsequence] || 4_294_967_295,
            description: inp[:description]
          )
          @db[:inputs].where(output_id: inp[:output_id], action_id: record_id).any?
        end
      end
    end
  end
end
