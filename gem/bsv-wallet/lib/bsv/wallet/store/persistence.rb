# frozen_string_literal: true

module BSV
  module Wallet
    module Store
      # Concrete SQL-backed implementation of Interface::Store.
      #
      # Orchestration logic lives in Store::Base; this class supplies the
      # database-specific adapter primitive:
      #
      #   - models           — the namespace of connection-bound model classes
      #   - try_lock_input   — input-claim detection, branched on database_type
      #                        because SQLite and Postgres differ in how
      #                        insert_conflict signals a DO NOTHING no-op
      class Persistence
        include BSV::Wallet::Interface::Store
        include BSV::Wallet::Store::Base

        def self.models
          BSV::Wallet::Store
        end

        def initialize(db: nil)
          @db = db || Connection.db
        end

        private

        # Attempt to claim an input row. Returns truthy iff this insert won
        # the race (i.e. no other action had already claimed this output).
        #
        # The branch is necessary because the two backends differ:
        #   - SQLite's insert_conflict returns last_insert_rowid even when
        #     DO NOTHING fires, so we re-query to verify ownership.
        #   - Postgres' insert_conflict returns nil on DO NOTHING, so the
        #     result is truthy iff this insert was the winner.
        def try_lock_input(record_id:, inp:)
          result = @db[:inputs].insert_conflict(target: :output_id).insert(
            action_id: record_id,
            output_id: inp[:output_id],
            vin: inp[:vin],
            nsequence: inp[:nsequence] || 4_294_967_295,
            description: inp[:description]
          )

          case @db.database_type
          when :postgres
            !!result
          else
            # SQLite (and any unknown backend): insert_conflict returns the
            # rowid even on DO NOTHING, so re-query to verify ownership.
            @db[:inputs].where(output_id: inp[:output_id], action_id: record_id).any?
          end
        end
      end
    end
  end
end
