# frozen_string_literal: true

# Persisted broadcast affinity. NULL means no affinity recorded yet --
# treated as "first-capable wins" by the selector. The wtxid is the
# bookkeeping key (broadcasts.action_id -> actions.wtxid), so this works
# even for Arcade's txid-less submit response.

Sequel.migration do
  change do
    add_column :broadcasts, :provider, :text
  end
end
