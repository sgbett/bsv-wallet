# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      module Store
        # Concrete PostgreSQL implementation of Interface::Store.
        #
        # Orchestration logic lives in BSV::Wallet::Store::Base; this class
        # supplies the Postgres-specific adapter primitives:
        #
        #   - models           — the namespace of connection-bound model classes
        #   - try_lock_input   — input-claim detection (Postgres' insert_conflict
        #                        returns nil on DO NOTHING, so the insert result
        #                        is truthy iff this insert won the race)
        class Postgres
          include BSV::Wallet::Interface::Store
          include BSV::Wallet::Store::Base

          def self.models
            BSV::Wallet::Postgres::Store
          end

          def initialize(db: nil)
            @db = db || Connection.db
          end

          private

          # Postgres' insert_conflict returns nil on DO NOTHING, so the
          # result is truthy iff this insert was the one that won the race.
          def try_lock_input(record_id:, inp:)
            !!@db[:inputs].insert_conflict(target: :output_id).insert(
              action_id:   record_id,
              output_id:   inp[:output_id],
              vin:         inp[:vin],
              nsequence:   inp[:nsequence] || 4_294_967_295,
              description: inp[:description]
            )
          end
        end
      end
    end
  end
end
