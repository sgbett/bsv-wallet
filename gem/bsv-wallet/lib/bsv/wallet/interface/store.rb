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

        # Phase 2: Attach wtxid and signed raw transaction to an action,
        # atomically queueing the broadcast.
        #
        # Updates the action with +wtxid+ and +raw_tx+, and (when
        # +actions.broadcast+ is not +'none'+) inserts the corresponding
        # +broadcasts+ row in the same database transaction. The row begins
        # life with +broadcast_at IS NULL+ (queued, not yet attempted).
        #
        # When +change_outputs+ is present, writes change output rows
        # (outputs + output_details) in the same transaction. No spendable
        # rows — promotion happens after broadcast acceptance. This ensures
        # signing failure produces zero orphan rows.
        #
        # Used by the real-signing paths (non-deferred +createAction+ and
        # BRC-100 +signAction+). The deferred +createAction+ path calls
        # {#stage_action} instead, which does not touch +broadcasts+.
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

        # Phase 2 (deferred): Attach placeholder signing artifacts to an action.
        #
        # Updates the action with +wtxid+ and +raw_tx+ but does NOT create a
        # +broadcasts+ row. Used by the deferred +createAction+ path where
        # +raw_tx+ carries placeholder unlocking scripts; the broadcast row
        # must wait for the real {#sign_action} call (via BRC-100
        # +signAction+) to avoid pushing an unsigned transaction to ARC.
        #
        # @param action_id [Integer]
        # @param wtxid [String] 32-byte binary wtxid (wire byte order)
        # @param raw_tx [String] binary-encoded transaction with placeholder
        #   unlocking scripts
        def stage_action(action_id:, wtxid:, raw_tx:)
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
        # @return [Array<Integer>] output IDs in the same order as outputs
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

        # Fail a broadcasted action. Removes the broadcast row first
        # (broadcasts has no cascade FK on action_id) and then deletes
        # the action. CASCADE on the other action-scoped tables releases
        # locked UTXOs and removes derivation/spendable records.
        #
        # Distinct from abort_action -- BRC-100 abortAction targets
        # actions under construction (no broadcast yet); this method
        # is for actions that were broadcast and observed terminal
        # via status polling.
        #
        # @param action_id [Integer]
        def fail_broadcast_action(action_id:)
          raise NotImplementedError
        end

        # --- Queries ---

        # Find an action by id, wtxid, or reference.
        #
        # @return [Hash, nil]
        def find_action(id: nil, wtxid: nil, reference: nil)
          raise NotImplementedError
        end

        # Find an output by id.
        #
        # @param id [Integer]
        # @return [Hash, nil] output data including :id, :action_id, :satoshis, :vout, etc.
        def find_output(id:)
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
        # Each output hash includes :id, :action_id, :satoshis, :vout, :spendable.
        #
        # @return [Hash] :total, :outputs
        def query_outputs(basket:, tags: nil, tag_query_mode: :any,
                          limit: 10, offset: 0,
                          include_locking_scripts: false,
                          include_custom_instructions: false,
                          include_tags: false, include_labels: false)
          raise NotImplementedError
        end

        # Query actions needing proof acquisition.
        #
        # Returns outgoing actions that have been signed (wtxid set) but
        # have no proof yet (tx_proof_id nil), excluding no-send actions
        # (broadcast: 'none') which receive proofs via other channels.
        #
        # @param limit [Integer] maximum records to return
        # @return [Array<Hash>] action hashes (same shape as find_action)
        def pending_proofs(limit: 100)
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

        # --- Proofs ---

        # Store a merkle proof for a transaction.
        #
        # Upserts — if a proof already exists for this wtxid, updates it.
        # Wraps the multi-table write (TxProof + Block) in a single transaction.
        #
        # @param wtxid [String] 32-byte binary wtxid (wire byte order)
        # @param proof [Hash] :height, :block_index, :merkle_path (binary),
        #   :raw_tx (binary), :block_hash (binary), :merkle_root (binary)
        # @return [Integer] the tx_proof ID
        def save_proof(wtxid:, proof:)
          raise NotImplementedError
        end

        # Retrieve a proof by wtxid.
        #
        # @param wtxid [String] 32-byte binary wtxid (wire byte order)
        # @return [Hash, nil] proof data, or nil if not stored
        def find_proof(wtxid:)
          raise NotImplementedError
        end

        # Check whether a proof exists for a transaction.
        #
        # @param wtxid [String] 32-byte binary wtxid (wire byte order)
        # @return [Boolean]
        def proof_exists?(wtxid:)
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

        # Promote change outputs to spendable for an action.
        #
        # Creates spendable rows for change outputs that don't already
        # have one. Called after broadcast acceptance or in the no_send path.
        #
        # @param action_id [Integer]
        def promote_change_to_spendable(action_id:)
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

        # --- Block Headers ---

        # Upsert a block header record.
        #
        # Accepts merkle_root and block_hash as either 32-byte binary or
        # 64-char hex strings. Already-binary values (Encoding::BINARY)
        # are stored as-is; hex strings are packed to binary.
        #
        # @param height [Integer] block height
        # @param merkle_root [String] 32-byte binary or 64-char hex string
        # @param block_hash [String, nil] 32-byte binary or 64-char hex string
        def record_block_header(height:, merkle_root:, block_hash: nil)
          raise NotImplementedError
        end

        # Find a block header by height.
        #
        # @param height [Integer]
        # @return [Hash, nil] { height:, merkle_root:, block_hash: } or nil
        def find_block(height:)
          raise NotImplementedError
        end

        # Return the maximum block height stored, or nil if no blocks.
        #
        # @return [Integer, nil]
        def max_block_height
          raise NotImplementedError
        end

        # --- Broadcasts ---

        # Record a broadcast result from ARC or a callback event.
        #
        # Find-or-creates a Broadcast record for the action, then updates
        # status fields atomically. Handles hex-to-binary decoding for
        # block_hash and merkle_path, and database-specific coercion for
        # competing_txs.
        #
        # @param action_id [Integer]
        # @param tx_status [String] e.g. 'SEEN_ON_NETWORK', 'MINED'
        # @param arc_status [Integer, nil] HTTP status from ARC
        # @param block_hash [String, nil] hex or binary block hash
        # @param block_height [Integer, nil]
        # @param merkle_path [String, nil] hex or binary merkle path
        # @param extra_info [String, nil]
        # @param competing_txs [Array<String>, nil]
        # @return [Hash] updated broadcast data
        def record_broadcast_result(action_id:, tx_status:, arc_status: nil,
                                    block_hash: nil, block_height: nil,
                                    merkle_path: nil, extra_info: nil,
                                    competing_txs: nil)
          raise NotImplementedError
        end

        # Query broadcast status for an action.
        #
        # @param action_id [Integer]
        # @return [Hash, nil] broadcast data or nil if no broadcast exists
        def broadcast_status(action_id:)
          raise NotImplementedError
        end

        # Query broadcasts eligible for status polling.
        #
        # Returns broadcasts that have been attempted (+broadcast_at IS NOT NULL+)
        # and whose +tx_status+ is not in the terminal set (or is still NULL,
        # which signals an in-flight or crash-recovery row). Under the
        # post-T2/T3 invariant, +broadcast_at+ is stamped pre-POST in the same
        # committed transaction, so this query is purely binary: any attempted
        # row not yet at a terminal status is the daemon's responsibility to
        # poll regardless of age. No staleness predicate.
        #
        # @param limit [Integer] maximum records to return
        # @return [Array<Hash>] broadcast data hashes
        def pending_polls(limit: 100)
          raise NotImplementedError
        end

        # Query broadcasts queued for an initial ARC submission.
        #
        # Returns broadcasts that have never been attempted (+broadcast_at IS NULL+).
        # Single-table scan, no join to actions. Under the #184 invariant a
        # broadcasts row implies a signed action, so no time math or staleness
        # predicate is needed -- a row in this state is by definition the
        # daemon's responsibility to push.
        #
        # @param limit [Integer] maximum records to return
        # @return [Array<Hash>] broadcast data hashes
        def pending_pushes(limit: 100)
          raise NotImplementedError
        end

        # Mark a broadcast row as attempted (stamp +broadcast_at+).
        #
        # Idempotent: only stamps rows where +broadcast_at IS NULL+. A row
        # that already has a stamp keeps the original timestamp -- this lets
        # the push and poll discovery loops race safely on the same row.
        #
        # Called by +Engine::Broadcast#submit+ in a committed transaction
        # immediately before the network call. A mid-POST crash therefore
        # leaves the row with +broadcast_at IS NOT NULL+ and +tx_status IS NULL+,
        # which the poll loop subsequently recovers via +GET /tx/{txid}+.
        #
        # @param action_id [Integer]
        def mark_broadcast_attempted(action_id:)
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
