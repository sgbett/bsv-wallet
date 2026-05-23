# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      # SQLite-specific store implementation.
      #
      # Applies PRAGMAs (foreign keys, WAL journal mode) and handles
      # SQLite's insert_conflict semantics where the return value is
      # always the last_insert_rowid, even on DO NOTHING — requiring
      # a re-query to verify input lock ownership.
      class SQLite < Store
        def configure_db
          @db.run('PRAGMA foreign_keys = ON')
          @db.run('PRAGMA journal_mode = WAL')
        end

        def try_lock_input(record_id:, inp:)
          super
          @db[:inputs].where(output_id: inp[:output_id], action_id: record_id).any?
        end
      end
    end
  end
end
