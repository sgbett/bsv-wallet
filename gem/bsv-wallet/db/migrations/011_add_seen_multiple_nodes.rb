# frozen_string_literal: true

# Adds SEEN_MULTIPLE_NODES to the tx_status enum.
#
# Discovered live during walletd validation against arcade.gorillapool.io:
# Arcade emits this status (between SEEN_ON_NETWORK and MINED) and the
# EventApplicator crashed with PG::InvalidTextRepresentation when trying
# to write it. The original ArcStatus taxonomy in 001_create_schema.rb
# missed it; this migration plugs the hole.
#
# Postgres-only: SQLite's tx_status is plain text, no enum constraint.
#
# Positioned in the enum AFTER 'SEEN_ON_NETWORK' to reflect the lifecycle
# order (more nodes have observed the tx = stronger propagation signal).

Sequel.migration do
  up do
    postgres = database_type == :postgres
    next unless postgres

    run "ALTER TYPE tx_status ADD VALUE IF NOT EXISTS 'SEEN_MULTIPLE_NODES' AFTER 'SEEN_ON_NETWORK'"
  end

  down do
    # Postgres does not support removing enum values without rebuilding
    # the entire type, which would require rewriting every column that
    # uses it. Down is a no-op; the extra value is harmless.
  end
end
