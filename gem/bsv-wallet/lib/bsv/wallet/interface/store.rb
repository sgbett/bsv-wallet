# frozen_string_literal: true

module BSV
  module Wallet
    module Interface
      # Persistence interface for wallet state.
      #
      # Methods mirror the schema's phase model — the action lifecycle is
      # create (lock inputs) → sign (attach wtxid) → promote (write outputs).
      # Status is derived from structural state, never stored directly.
      #
      # All methods receive and return plain hashes/arrays — no ORM objects
      # leak through the interface boundary.
      module Store
        # --- Action Lifecycle ---

        # Phase 1: Create an action and lock inputs atomically.
        #
        # Inserts an action row and input rows in one transaction.
        # Input locking uses INSERT ON CONFLICT — concurrent callers
        # competing for the same outputs are resolved by the database.
        #
        # @param action [Hash] :description, :broadcast (:delayed/:inline/:none),
        #   :nlocktime, :version, :input_beef, :outgoing
        # @param inputs [Array<Hash>] each: :output_id, :vin, :nsequence, :description
        # @return [Hash] the created action with :id, :reference
        # @raise [InsufficientFundsError] if not enough inputs could be locked
        def create_action(action:, inputs: [])
          raise NotImplementedError
        end

        # Phase 2: Attach wtxid and signed raw transaction to an action.
        #
        # When +change_outputs+ is present, writes change output rows
        # (outputs, spendable, output_details) atomically within the same
        # database transaction. This ensures signing failure produces zero
        # orphan output rows.
        #
        # @param action_id [Integer]
        # @param wtxid [String] 32-byte binary wtxid (wire byte order)
        # @param raw_tx [String] binary-encoded signed transaction
        # @param change_outputs [Array<Hash>] optional change outputs to write
        #   atomically. Each: :satoshis, :vout, :locking_script,
        #   :derivation_prefix, :derivation_suffix, :sender_identity_key
        def sign_action(action_id:, wtxid:, raw_tx:, change_outputs: [])
          raise NotImplementedError
        end

        # Phase 4: Promote — write outputs after broadcast acceptance.
        #
        # Inserts output rows (immutable log), spendable entries,
        # basket memberships, output details, and tags in one transaction.
        #
        # @param action_id [Integer]
        # @param outputs [Array<Hash>] each: :satoshis, :vout, :locking_script,
        #   :derivation_prefix, :derivation_suffix, :sender_identity_key,
        #   :basket, :tags, :description, :custom_instructions, :change
        def promote_action(action_id:, outputs:)
          raise NotImplementedError
        end

        # Link a merkle proof to an action (marks it as completed).
        #
        # @param action_id [Integer]
        # @param tx_proof_id [Integer]
        def link_proof(action_id:, tx_proof_id:)
          raise NotImplementedError
        end

        # Abort an action. CASCADE deletes inputs, releasing locked UTXOs.
        # Only valid for unsigned actions (wtxid IS NULL).
        #
        # @param action_id [Integer]
        def abort_action(action_id:)
          raise NotImplementedError
        end

        # --- Queries ---

        # Find an action by id, wtxid, or reference.
        #
        # @return [Hash, nil]
        def find_action(id: nil, wtxid: nil, reference: nil)
          raise NotImplementedError
        end

        # Query actions by labels with pagination.
        #
        # @return [Hash] :total, :actions
        def query_actions(labels:, label_query_mode: :any, limit: 10, offset: 0,
                          include_labels: false, include_inputs: false,
                          include_input_locking_scripts: false,
                          include_input_unlocking_scripts: false,
                          include_outputs: false, include_output_locking_scripts: false)
          raise NotImplementedError
        end

        # Query spendable outputs in a basket with optional tag filtering.
        #
        # @return [Hash] :total, :outputs
        def query_outputs(basket:, tags: nil, tag_query_mode: :any,
                          limit: 10, offset: 0,
                          include_locking_scripts: false,
                          include_custom_instructions: false,
                          include_tags: false, include_labels: false)
          raise NotImplementedError
        end

        # --- Outputs ---

        # Remove an output from the UTXO set and its basket.
        # The output row stays in the immutable log.
        #
        # @param output_id [Integer]
        def relinquish_output(output_id:)
          raise NotImplementedError
        end

        # --- Labels, Tags, Baskets ---

        # Find or create labels by name. Returns an array of label IDs.
        def find_or_create_labels(names:)
          raise NotImplementedError
        end

        # Find or create tags by name. Returns an array of tag IDs.
        def find_or_create_tags(names:)
          raise NotImplementedError
        end

        # Find or create a basket by name. Returns the basket ID.
        def find_or_create_basket(name:)
          raise NotImplementedError
        end

        # Attach labels to an action.
        def label_action(action_id:, label_ids:)
          raise NotImplementedError
        end

        # --- Certificates ---

        # Persist a certificate with its fields.
        def save_certificate(certificate)
          raise NotImplementedError
        end

        # Query certificates by certifiers and types.
        #
        # @return [Hash] :total, :certificates
        def query_certificates(certifiers:, types:, limit: 10, offset: 0)
          raise NotImplementedError
        end

        # Soft-delete a certificate.
        def delete_certificate(type:, serial_number:, certifier:)
          raise NotImplementedError
        end

        # --- Settings ---

        # Retrieve a setting value by key.
        #
        # @return [String, nil]
        def get_setting(key:)
          raise NotImplementedError
        end

        # Set a setting value (upsert).
        def set_setting(key:, value:)
          raise NotImplementedError
        end

        # --- Input Resolution ---

        # Resolve the full context for each locked input of an action.
        #
        # Joins inputs → outputs → actions (the action that *created* the
        # output, not the current action) to gather the source outpoint,
        # satoshis, locking script, and derivation parameters needed for
        # transaction construction and signing.
        #
        # @param action_id [Integer]
        # @return [Array<Hash>] ordered by vin, each:
        #   :vin, :sequence, :source_wtxid (32-byte binary, wire byte order),
        #   :source_vout, :source_satoshis, :source_locking_script (binary),
        #   :derivation_prefix, :derivation_suffix, :sender_identity_key
        # @raise [RuntimeError] if any source action has a nil wtxid
        def resolve_inputs_for_signing(action_id:)
          raise NotImplementedError
        end

        # --- Change Output Queries ---

        # Return vout positions of change outputs for an action.
        #
        # Queries outputs joined to output_details where change is true.
        # Used by Engine#query_change_outpoints for the no_send_change response.
        #
        # @param action_id [Integer]
        # @return [Array<Integer>] vout positions
        def query_change_output_vouts(action_id:)
          raise NotImplementedError
        end

        # --- UTXO Selection ---

        # Find spendable outputs totalling at least the required satoshis.
        # This is the database-level query — the UTXOPool wraps this
        # with a selection strategy for higher tiers.
        #
        # @param satoshis [Integer] minimum total value needed
        # @param basket [String, nil] optional basket filter
        # @param exclude [Array<Integer>] output IDs to skip (e.g. from a failed lock attempt)
        # @return [Array<Hash>] candidates: :id, :satoshis, :vout, :locking_script, :action_id
        def find_spendable(satoshis:, basket: nil, exclude: [])
          raise NotImplementedError
        end

        # --- Reaper ---

        # Delete stale unsigned or unbroadcast actions older than the threshold.
        # CASCADE deletes inputs, releasing locked UTXOs.
        #
        # @param threshold [Integer] age in seconds
        # @return [Integer] number of actions reaped
        def reap_stale_actions(threshold:)
          raise NotImplementedError
        end
      end
    end
  end
end
