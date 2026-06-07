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

        # Phase 1 (top-up): Append additional input rows to an existing action.
        #
        # Locks each output by inserting an inputs row with ON CONFLICT
        # DO NOTHING on +output_id+. All-or-nothing: if any input fails
        # to lock (another action already owns the output), the whole
        # batch is rolled back and 0 is returned. Mirrors {#create_action}'s
        # Phase 1 locking semantics so the engine's funding loop can request
        # additional UTXOs after the initial lock without re-implementing
        # the contention path.
        #
        # An empty +inputs+ array is a no-op and returns 0.
        #
        # @param action_id [Integer] target action (must exist)
        # @param inputs [Array<Hash>] each: :output_id, :vin, :nsequence, :description
        # @return [Integer] number of input rows locked (size of +inputs+ on
        #   success, 0 on rollback or empty input)
        def lock_inputs(action_id:, inputs:)
          raise NotImplementedError
        end

        # Phase 2: Attach wtxid and signed raw transaction to an action,
        # atomically queueing the broadcast.
        #
        # Updates the action with +wtxid+ and +raw_tx+, and (when
        # +actions.broadcast_intent+ is not +'none'+) inserts the corresponding
        # +broadcasts+ row in the same database transaction. The row begins
        # life with +broadcast_at IS NULL+ (queued, not yet attempted).
        #
        # When +outputs+ or +change_outputs+ are present, writes the
        # corresponding output rows (with +promoted: false+) and their
        # association rows (output_details, output_baskets, output_tags)
        # in the same transaction. No spendable rows — promotion to the
        # canonical UTXO set happens at Phase 4 via {#promote_action_outputs}
        # on broadcast acceptance. This ensures signing failure produces
        # zero orphan rows in the UTXO set.
        #
        # Used by the real-signing paths (non-deferred +createAction+ and
        # BRC-100 +signAction+). The deferred +createAction+ path calls
        # {#stage_action} instead, which does not touch +broadcasts+.
        #
        # @param action_id [Integer]
        # @param wtxid [String] 32-byte binary wtxid (wire byte order)
        # @param raw_tx [String] binary-encoded signed transaction
        # @param outputs [Array<Hash>] optional caller-declared outputs to write
        #   atomically with +promoted: false+. Each: :satoshis, :vout,
        #   :locking_script, :output_type, :derivation_prefix,
        #   :derivation_suffix, :sender_identity_key, :basket, :tags,
        #   :description, :custom_instructions
        # @param change_outputs [Array<Hash>] optional change outputs to write
        #   atomically with +promoted: false+. Each: :satoshis, :vout,
        #   :locking_script, :derivation_prefix, :derivation_suffix,
        #   :sender_identity_key
        def sign_action(action_id:, wtxid:, raw_tx:, outputs: [], change_outputs: [])
          raise NotImplementedError
        end

        # Phase 2 (deferred): Attach placeholder signing artifacts and the
        # caller's declared outputs to an action.
        #
        # Updates the action with +wtxid+ and +raw_tx+ but does NOT create a
        # +broadcasts+ row. Used by the deferred +createAction+ path where
        # +raw_tx+ carries placeholder unlocking scripts; the broadcast row
        # must wait for the real {#sign_action} call (via BRC-100
        # +signAction+) to avoid pushing an unsigned transaction to ARC.
        #
        # Outputs are written with +promoted: false+ (no spendable rows yet)
        # so the BRC-100 +signAction+ — which does not receive the +outputs+
        # array again — finds the caller's metadata already persisted. Phase 4
        # promotion happens later via {#promote_action_outputs} on broadcast
        # acceptance.
        #
        # @param action_id [Integer]
        # @param wtxid [String] 32-byte binary wtxid (wire byte order)
        # @param raw_tx [String] binary-encoded transaction with placeholder
        #   unlocking scripts
        # @param outputs [Array<Hash>] caller's declared outputs to persist
        #   with +promoted: false+. Each: :satoshis, :vout, :locking_script,
        #   :output_type, :derivation_prefix, :derivation_suffix,
        #   :sender_identity_key, :basket, :tags, :description,
        #   :custom_instructions
        def stage_action(action_id:, wtxid:, raw_tx:, outputs: [])
          raise NotImplementedError
        end

        # Internal-path Phase 4: Write outputs as already promoted.
        #
        # Inserts output rows (+promoted: true+), spendable entries for
        # wallet-owned outputs, basket memberships, output details, and tags
        # in one transaction. Used by paths where the action's broadcast
        # intent is +'none'+ — incoming actions, root UTXO imports, wbikd —
        # so outputs join the canonical UTXO set immediately.
        #
        # @param action_id [Integer]
        # @param outputs [Array<Hash>] each: :satoshis, :vout, :locking_script,
        #   :derivation_prefix, :derivation_suffix, :sender_identity_key,
        #   :basket, :tags, :description, :custom_instructions, :change
        # @return [Array<Integer>] output IDs in the same order as outputs
        def promote_action(action_id:, outputs:)
          raise NotImplementedError
        end

        # Send-path Phase 4: Promote pre-existing output rows for an action.
        #
        # Flips +outputs.promoted+ from false to true and inserts spendable
        # rows for wallet-owned outputs (caller outputs with derivation
        # parameters, root outputs, or change outputs). Idempotent — outputs
        # already promoted are skipped, and existing spendable rows are not
        # duplicated.
        #
        # Called when ARC accepts a broadcast (inline or via the daemon).
        # The output rows themselves were written at sign time via
        # {#sign_action} with +promoted: false+.
        #
        # @param action_id [Integer]
        # @return [Array<Integer>] IDs of outputs newly promoted (empty when
        #   already promoted — idempotent guard)
        def promote_action_outputs(action_id:)
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

        # Reject a broadcast action whose terminal outcome was REJECTED.
        # Unwinds speculatively-promoted outputs and cascades forward
        # through any child action that consumed this action's outputs.
        # Single outer transaction; partial-cascade failures roll back
        # the entire walk.
        #
        # Distinct from abort_action -- BRC-100 abortAction targets
        # actions under construction (pre-broadcast cancel, refuses on
        # promoted outputs). reject_action is for the post-broadcast
        # rejection path where promotion was an optimistic bet now
        # contradicted by the network.
        #
        # Raises +BSV::Wallet::CannotRejectInternalActionError+ if the
        # target or any cascade descendant has broadcast_intent='none'.
        # Internal-path actions are not the domain of this method.
        #
        # Raises +BSV::Wallet::CannotRejectAcceptedActionError+ if the
        # target or any cascade descendant has a broadcast row whose
        # tx_status is in +BSV::Wallet::ArcStatus::ACCEPTED+. The
        # network considers the tx accepted; unwind would corrupt the
        # wallet's view rather than recover it. Operator investigation
        # is the right response.
        #
        # @param action_id [Integer]
        def reject_action(action_id:)
          raise NotImplementedError
        end

        # Return action_ids of every action whose inputs spend an
        # output of +action_id+. The forward-walk for the reject_action
        # cascade.
        #
        # @param action_id [Integer]
        # @return [Array<Integer>]
        def child_actions_of(action_id:)
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
        # (broadcast_intent: 'none') which receive proofs via other channels.
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

        # Persist broadcast affinity: the provider that handled this wtxid.
        #
        # Looks up the action by wtxid, then sets +broadcasts.provider+ on
        # the matching broadcast row. Used by +BSV::Network::Broadcaster+
        # to record which provider accepted the broadcast so a fresh
        # broadcaster (e.g. after daemon restart) can re-route status
        # queries to the same provider.
        #
        # Idempotent: re-recording the same +(wtxid, provider)+ is a no-op.
        # A subsequent call with a different provider overwrites the column
        # (last-broadcaster wins). No-op when no matching action or
        # broadcast row exists (race with action deletion).
        #
        # @param wtxid [String] 32-byte binary wire-order wtxid
        # @param provider [String] provider name (e.g. +"GorillaPool"+)
        # @return [Integer] number of rows updated (0 or 1)
        def record_broadcast_provider(wtxid:, provider:)
          raise NotImplementedError
        end

        # Read broadcast affinity: the provider name for a given wtxid.
        #
        # Resolves the wtxid to its action then reads
        # +broadcasts.provider+. Returns +nil+ when no action matches, no
        # broadcasts row exists, or the column is NULL (no affinity yet).
        #
        # @param wtxid [String] 32-byte binary wire-order wtxid
        # @return [String, nil] provider name, or +nil+ if no affinity recorded
        def broadcast_provider_for(wtxid:)
          raise NotImplementedError
        end

        # Query broadcasts the resolution loop should poll to terminal.
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
        def pending_resolutions(limit: 100)
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
        def pending_submissions(limit: 100)
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

        # Increment broadcasts.retry_count for an action. Called from the
        # resolution loop when reject_action raises
        # CannotRejectInternalActionError -- the row stays alive for the
        # next polling cycle but the counter surfaces stuck rows for
        # dashboards.
        #
        # @param action_id [Integer]
        def increment_broadcast_retry(action_id:)
          raise NotImplementedError
        end

        # --- SSE Cursors ---

        # Load the high-water Last-Event-ID for an Arcade SSE callback token.
        #
        # Returns +nil+ for an unknown token, signalling the listener to
        # connect without a +Last-Event-ID+ header (fresh stream).
        #
        # @param token [String] Arcade callbackToken value
        # @return [Integer, nil] last successfully bus-pushed event id
        #   (nanosecond timestamp per Arcade SSE), or +nil+ if never seen
        def load_sse_cursor(token:)
          raise NotImplementedError
        end

        # Persist the high-water Last-Event-ID for an Arcade SSE token.
        #
        # Upsert keyed on +token+: a second save for the same token
        # overwrites the previous +last_event_id+ rather than raising a
        # PK violation. Used by the SSE listener after each event has
        # been handed off to the in-proc bus -- the cursor reflects what
        # has been pushed, so a reconnect resumes from the next frame.
        #
        # @param token [String] Arcade callbackToken value
        # @param last_event_id [Integer] SSE id of the most recently
        #   pushed event (nanosecond timestamp)
        def save_sse_cursor(token:, last_event_id:)
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
