# frozen_string_literal: true

Sequel.migration do
  change do
    add_column :output_details, :change, :boolean, default: false, null: false
  end
end
