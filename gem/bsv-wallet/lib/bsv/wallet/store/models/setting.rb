# frozen_string_literal: true

module BSV
  module Wallet
    module Store
      class Setting < Sequel::Model
        plugin :timestamps, update_on_create: true

        # Retrieve a setting value by key.
        #
        # @param key [String]
        # @return [String, nil]
        def self.get(key)
          first(key: key)&.value
        end

        # Set a setting value (upsert).
        #
        # @param key [String]
        # @param value [String]
        def self.set(key, value)
          record = first(key: key)
          if record
            record.update(value: value)
          else
            create(key: key, value: value)
          end
        end
      end
    end
  end
end
