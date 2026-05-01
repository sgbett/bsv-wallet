# frozen_string_literal: true

Sequel.migration do
  up do
    add_column :actions, :pending_outputs, :jsonb
  end

  down do
    drop_column :actions, :pending_outputs
  end
end
