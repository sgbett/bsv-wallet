# frozen_string_literal: true

require 'omq'

module BSV
  module Wallet
    class Engine
      # Background broadcast handler -- logical model for walletd.
      #
      # Owns OMQ sockets for background work (PULL) and inline
      # request-reply (REP). Processes pending broadcasts by calling
      # Services and recording results in Store. Also owns the statuses
      # PULL socket for SSE-delivered events (#265): the Network-layer
      # SSE listener PUSHes decoded event hashes here, this fiber PULLs
      # and hands off to Store::EventApplicator for atomic application.
      class Broadcast
        include OmqSupport

        # @param store        [BSV::Wallet::Store]
        # @param broadcaster  [BSV::Network::Broadcaster]
        # @param applicator   [Store::EventApplicator, nil] consumes statuses
        #   events on +statuses_pull!+. Lazily defaulted to a fresh
        #   +Store::EventApplicator.new(store: store)+ on first read so
        #   existing call sites (pre-#265 specs, the inline path) don't
        #   trigger autoload of Store::EventApplicator (and its Sequel
        #   dependency chain) at construction time; #265's Daemon wiring
        #   supplies its own instance.
        # @param callback_token [String, nil] Arcade callbackToken; passed
        #   to +Broadcaster#broadcast+ on every submit so the +X-CallbackToken+
        #   header is set on the POST and Arcade's SSE listener (subscribed
        #   to the same token) receives the resulting status frames. Lenient
        #   default (nil) lets unit specs that do not run a listener exercise
        #   submit without the header.
        def initialize(store:, broadcaster:, applicator: nil, callback_token: nil)
          @store = store
          @broadcaster = broadcaster
          @applicator = applicator
          @callback_token = callback_token
        end

        # Lazy default — see +#initialize+.
        def applicator
          @applicator ||= BSV::Wallet::Store::EventApplicator.new(store: @store)
        end

        # Background queue -- fire-and-forget processing.
        # Binds a PULL socket; the Scheduler pushes action IDs here.
        def pull!(task:)
          task.async do
            pull = bind_or_die('broadcast_worker') { OMQ::PULL.bind('inproc://broadcasts.pull') }
            while (msg = pull.receive)
              begin
                process(msg.first.to_i)
              rescue StandardError => e
                BSV.logger&.error { "[Engine::Broadcast] pull error: #{e.message}" }
              end
            end
          end
          self
        end

        # Statuses queue -- consumes SSE-delivered events. Binds a PULL
        # socket at +inproc://statuses.pull+; the SSE listener fiber
        # (Daemon-wired in #265) PUSHes Marshal-encoded event hashes
        # here. Each message decodes into the shape
        # +Store::EventApplicator#apply+ consumes -- the same internal
        # event hash the Rack callback hands off, since the listener's
        # +decode_event+ normalises into that shape pre-PUSH.
        #
        # Runs as a peer fiber to +pull!+/+reply!+. The two PULL sockets
        # live in separate Async tasks, so the reactor schedules them
        # fairly; one busy socket does not starve the other.
        #
        # Marshal (not JSON) for the wire format -- the event hash carries
        # binary +wtxid+ / +block_hash+ / +merkle_path+ that would need
        # hex round-tripping under JSON. Marshal is the simplest in-proc
        # Ruby-to-Ruby encoding and keeps the convention (binary stays
        # binary) intact across the bus.
        def statuses_pull!(task:)
          task.async do
            pull = bind_or_die('statuses_worker') { OMQ::PULL.bind('inproc://statuses.pull') }
            while (msg = pull.receive)
              begin
                event = Marshal.load(msg.first) # rubocop:disable Security/MarshalLoad
                applicator.apply(event)
              rescue StandardError => e
                BSV.logger&.error { "[Engine::Broadcast] statuses_pull error: #{e.message}" }
              end
            end
          end
          self
        end

        # Inline request-reply -- caller sends action_id, gets tx_status back.
        def reply!(task:)
          task.async do
            rep = bind_or_die('broadcast_worker') { OMQ::REP.bind('inproc://broadcasts.rep') }
            while (msg = rep.receive)
              begin
                result = process(msg.first.to_i)
                rep << (result ? result[:tx_status].to_s : 'error')
              rescue StandardError => e
                BSV.logger&.error { "[Engine::Broadcast] reply error: #{e.message}" }
                rep << 'error'
              end
            end
          end
          self
        end

        # Process a single action -- submit if not yet broadcast, poll status
        # if already broadcast. Emits exactly one task.dispatched on entry,
        # then exactly one of task.succeeded / task.failed / task.aborted /
        # task.skipped. The emitted +task+ label reflects which loop's work
        # this represents: +broadcast_submission+ for a first-attempt push,
        # +broadcast_resolution+ for status polling.
        def process(action_id)
          started_at = Time.now
          status = @store.broadcast_status(action_id: action_id)
          task_name = status && status[:broadcast_at] ? 'broadcast_resolution' : 'broadcast_submission'
          BSV::Wallet.emit('task.dispatched', task: task_name, id: action_id)

          begin
            action = @store.find_action(id: action_id)
            unless action
              BSV::Wallet.emit('task.skipped', task: task_name, id: action_id, reason: :action_not_found)
              return
            end
            unless action[:raw_tx]
              BSV::Wallet.emit('task.skipped', task: task_name, id: action_id, reason: :no_raw_tx)
              return
            end

            if status && status[:broadcast_at]
              poll_status(action_id, action, status: status, started_at: started_at)
            else
              submit(action_id, action, started_at: started_at)
            end
          rescue StandardError => e
            # Every dispatched task must emit exactly one terminal event so the
            # Scheduler's in_flight counter (and cooperative drain) stays
            # balanced -- an exception bubbling out of submit/poll_status would
            # otherwise leave in_flight stuck >0. Emit the terminal event, then
            # re-raise so pull!/reply! still log and the REP path answers 'error'.
            BSV::Wallet.emit('task.failed', task: task_name, id: action_id,
                                            reason: :exception, error: e.message)
            raise
          end
        end

        # Discovery query -- returns action IDs of attempted, non-terminal
        # broadcasts (eligible for the resolution loop's status poll).
        # Pre-broadcast actions (no Broadcasts row, or broadcast_at IS NULL)
        # are not returned here; submission discovery is via .pending_submissions.
        def self.pending_resolutions(store, limit: 10)
          store.pending_resolutions(limit: limit).map { |b| b[:action_id] }
        end

        # Discovery query -- returns action IDs of broadcasts that have
        # never been attempted (broadcast_at IS NULL). Counterpart to
        # .pending_resolutions: this drives the submission loop. Both feed
        # the same PULL socket; +process+ routes them by broadcast_at presence.
        def self.pending_submissions(store, limit: 10)
          store.pending_submissions(limit: limit).map { |b| b[:action_id] }
        end

        private

        # Parse +action[:raw_tx]+ into a Transaction and re-attach per-input
        # source data (+source_satoshis+ / +source_locking_script+) from the
        # Store so the SDK can serialize Extended Format. Inputs are ordered
        # by +inputs.vin+, which matches the order of +tx.inputs+ from the
        # raw-tx parse.
        #
        # @param action [Hash] action record carrying +:id+ and +:raw_tx+
        # @return [BSV::Transaction::Transaction]
        # @raise [BSV::Wallet::Error] when the DB input count disagrees with
        #   the parsed transaction's input count (a contract violation
        #   upstream; should never fire under the normal create_action flow).
        def hydrated_transaction_for(action)
          tx = BSV::Transaction::Transaction.from_binary(action[:raw_tx])
          sources = @store.resolve_inputs_for_signing(action_id: action[:id])
          if tx.inputs.length != sources.length
            raise BSV::Wallet::Error,
                  "input count mismatch action_id=#{action[:id]} " \
                  "tx=#{tx.inputs.length} db=#{sources.length}"
          end

          tx.inputs.each_with_index { |input, idx| InputSource.attach!(input, sources[idx]) }
          tx
        end

        # Initial broadcast -- submit Extended Format to ARC.
        #
        # Reconstructs the Transaction from +action[:raw_tx]+ + per-input
        # source data via #hydrated_transaction_for so the SDK's broadcaster
        # serializes to EF (Arcade rejects raw-tx submits with "'PreviousTx'
        # not supplied"). The inline path passes its in-memory Transaction
        # directly; the daemon path reconstructs from the DB. #252.
        #
        # Stamps broadcast_at in a committed transaction *before* the
        # network call (plan §4.2 / §4.3). A mid-POST crash therefore
        # leaves the row in broadcast_at IS NOT NULL, tx_status IS NULL --
        # a recognisable crash-recovery state that the poll loop / SSE
        # listener subsequently resolves.
        #
        # Dispatch by HTTP status (#266 / plan §4.2):
        #   202 -> record_broadcast_results (today's success path)
        #   400 -> reject_action when the body carries a terminal txStatus;
        #          a 400 without txStatus stays alive for the resolution
        #          loop (some ARC 400s are non-terminal, see #266 edge case)
        #   503 -> clear_broadcast_attempted; daemon re-pulls next cycle.
        #          The clear is guarded against the listener-race in
        #          Store#clear_broadcast_attempted (where tx_status IS NULL)
        #   other 4xx/5xx -> existing transient/transport handling
        #
        # Crash-between-503-and-clear leaves the row stuck in "submitted,
        # awaiting outcome" until the poll loop / listener resolves it.
        # Bounded recovery, not a correctness issue (plan §4.3).
        def submit(action_id, action, started_at:)
          # wtxid_raw_tx_parity (migration 003) guarantees wtxid is set
          # whenever raw_tx is — the #process guard above filtered out the
          # NULL raw_tx case. Validate defensively so a contract violation
          # surfaces here rather than deep inside Broadcaster.
          BSV::Primitives::Hex.validate_wtxid!(action[:wtxid], name: 'Engine::Broadcast#submit wtxid')

          @store.mark_broadcast_attempted(action_id: action_id)
          # Hydrate a Transaction from raw_tx + DB-resolved source data so
          # the SDK can serialize Extended Format on the wire (Arcade rejects
          # raw-tx submits with "'PreviousTx' not supplied"). The inline path
          # already ships a Transaction; #252 closes the daemon-side gap.
          tx = hydrated_transaction_for(action)
          # Conditional kwarg: Broadcaster also drops nil callback_token to
          # avoid polluting the Provider#call signature, but skipping it
          # here keeps Engine::Broadcast#submit specs free of the kwarg
          # when no token is configured (the lenient-default case).
          broadcast_kwargs = { wtxid: action[:wtxid] }
          broadcast_kwargs[:callback_token] = @callback_token if @callback_token
          response = @broadcaster.broadcast(tx, **broadcast_kwargs)
          latency_ms = ((Time.now - started_at) * 1000).round

          if response.http_success?
            handle_submit_success(action_id, response, latency_ms: latency_ms)
          elsif backpressure?(response)
            handle_submit_backpressure(action_id, response, latency_ms: latency_ms)
          elsif terminal_failure?(response)
            handle_submit_terminal(action_id, response)
          else
            BSV::Wallet.emit('task.failed',
                             task: 'broadcast_submission', id: action_id,
                             latency_ms: latency_ms,
                             reason: categorize_reason(response))
            @store.broadcast_status(action_id: action_id)
          end
        end

        # 202 success branch -- record the ARC response (which atomically
        # promotes outputs in the same Store transaction).
        def handle_submit_success(action_id, response, latency_ms:)
          # Success responses are normalized by BSV::Network::Services
          # to symbol + snake_case keys. Failure responses (below) are
          # returned raw from the provider (string + camelCase).
          data = response.data
          updated = @store.record_broadcast_result(
            action_id: action_id,
            tx_status: data[:tx_status],
            arc_status: data[:status],
            block_hash: data[:block_hash],
            block_height: data[:block_height],
            merkle_path: data[:merkle_path],
            extra_info: data[:extra_info],
            competing_txs: data[:competing_txs]
          )
          # Phase 4 promotion is now atomic with the result recording
          # above — Store#record_broadcast_result promotes outputs in the
          # same transaction when tx_status is accepted. No separate call
          # needed here; closes the crash-recovery gap where a process
          # could die between recording and promotion.
          BSV::Wallet.emit('task.succeeded',
                           task: 'broadcast_submission', id: action_id,
                           latency_ms: latency_ms,
                           outcome: categorize_outcome(data[:tx_status]))
          updated
        end

        # 400 / terminal-body branch -- under HLR #182's atomic invariant,
        # the broadcasts row already exists by submit time. Use reject_action
        # to cascade-unwind any speculatively-promoted descendants and
        # release locked UTXOs. If the cascade hits a no_send descendant
        # the call raises -- bump retry_count, leave the row alive for the
        # next resolution-loop pass, and emit a failure event.
        def handle_submit_terminal(action_id, response)
          @store.reject_action(action_id: action_id)
          BSV::Wallet.emit('task.aborted',
                           task: 'broadcast_submission', id: action_id,
                           reason: categorize_reason(response),
                           arc_status: response.data['txStatus'])
          nil
        rescue BSV::Wallet::CannotRejectInternalActionError => e
          @store.increment_broadcast_retry(action_id: action_id)
          BSV::Wallet.emit('task.failed',
                           task: 'broadcast_submission', id: action_id,
                           reason: :cannot_reject_internal_action,
                           error: e.message)
          @store.broadcast_status(action_id: action_id)
        end

        # 503 backpressure branch -- Arcade returns 503 (with optional
        # Retry-After) when the validator queue is full. Clear the pre-call
        # +broadcast_at+ stamp so the row re-enters the queued set, log
        # the deferral, and emit a task.failed event so the Scheduler's
        # in_flight counter balances. The daemon's pending_submissions
        # discovery picks the row back up next cycle.
        def handle_submit_backpressure(action_id, _response, latency_ms:)
          @store.clear_broadcast_attempted(action_id: action_id)
          BSV::Wallet.emit('task.failed',
                           task: 'broadcast_submission', id: action_id,
                           latency_ms: latency_ms,
                           reason: :backpressure)
          @store.broadcast_status(action_id: action_id)
        end

        # Status poll -- query ARC for current tx status.
        #
        # Aborts on a terminal txStatus (REJECTED, DOUBLE_SPEND_ATTEMPTED,
        # or ORPHAN in extraInfo). Terminal-reject routes through
        # Store#reject_action, which cascades-forward through any child
        # action that consumed this action's outputs and unwinds the
        # speculative promotion in one transaction. CannotRejectInternalActionError
        # is the no_send-descendant invariant guard -- bump retry_count and
        # leave the row alive for the next resolution-loop pass.
        def poll_status(action_id, action, status:, started_at:)
          unless action[:wtxid]
            BSV::Wallet.emit('task.skipped', task: 'broadcast_resolution', id: action_id, reason: :no_wtxid)
            return status
          end

          dtxid = action[:wtxid].reverse.unpack1('H*')
          response = @broadcaster.get_tx_status(wtxid: action[:wtxid], dtxid: dtxid)
          latency_ms = ((Time.now - started_at) * 1000).round

          if response.http_success?
            data = response.data
            if terminal_status?(data[:tx_status], data[:extra_info])
              begin
                @store.reject_action(action_id: action_id)
                BSV::Wallet.emit('task.aborted',
                                 task: 'broadcast_resolution', id: action_id,
                                 reason: categorize_terminal_reason(data[:tx_status], data[:extra_info]),
                                 arc_status: data[:tx_status])
                return nil
              rescue BSV::Wallet::CannotRejectInternalActionError => e
                @store.increment_broadcast_retry(action_id: action_id)
                BSV::Wallet.emit('task.failed',
                                 task: 'broadcast_resolution', id: action_id,
                                 reason: :cannot_reject_internal_action,
                                 error: e.message)
                return status
              end
            end

            updated = @store.record_broadcast_result(
              action_id: action_id,
              tx_status: data[:tx_status],
              arc_status: data[:status],
              block_hash: data[:block_hash],
              block_height: data[:block_height],
              merkle_path: data[:merkle_path],
              extra_info: data[:extra_info],
              competing_txs: data[:competing_txs]
            )
            # Phase 4 promotion is atomic with the result recording above
            # (Store#record_broadcast_result) when tx_status is accepted.
            BSV::Wallet.emit('task.succeeded',
                             task: 'broadcast_resolution', id: action_id,
                             latency_ms: latency_ms,
                             outcome: categorize_outcome(data[:tx_status]))
            updated
          else
            BSV::Wallet.emit('task.failed',
                             task: 'broadcast_resolution', id: action_id,
                             latency_ms: latency_ms,
                             reason: categorize_reason(response))
            status
          end
        end

        # Categorize a successful ARC txStatus into an outcome bucket.
        def categorize_outcome(tx_status)
          status = tx_status.to_s.upcase
          if ArcStatus::ACCEPTED.include?(status)
            :accepted
          elsif ArcStatus::REJECTED.include?(status)
            :rejected
          else
            :pending
          end
        end

        # Categorize a failure response into a reason bucket.
        def categorize_reason(response)
          if response.data
            tx_status = response.data['txStatus'].to_s.upcase
            return :stale_beef if tx_status == 'MINED_IN_STALE_BLOCK'

            categorize_terminal_reason(response.data['txStatus'], response.data['extraInfo'])
          elsif response.retryable?
            response.code.to_i == 429 ? :rate_limited : :transport_error
          else
            :malformed
          end
        end

        # Categorize a terminal-status payload (from either an ARC failure
        # response's data hash or a successful get_tx_status payload) into
        # a reason bucket. Excludes MINED_IN_STALE_BLOCK -- that is
        # transient, not terminal, and handled upstream.
        def categorize_terminal_reason(tx_status, extra_info)
          status = tx_status.to_s.upcase
          info = extra_info.to_s.upcase
          return :double_spend if status == 'DOUBLE_SPEND_ATTEMPTED'
          return :policy_violation if status == 'REJECTED'
          return :policy_violation if status.include?('ORPHAN') || info.include?('ORPHAN')

          :unknown
        end

        # True when the txStatus + extraInfo indicate a definitive,
        # non-recoverable rejection. Used by both submit (failure path)
        # and poll (success path with terminal txStatus).
        def terminal_status?(tx_status, extra_info = nil)
          status = tx_status.to_s.upcase
          return true if ArcStatus::REJECTED.include?(status)

          info = extra_info.to_s.upcase
          status.include?('ORPHAN') || info.include?('ORPHAN')
        end

        # True when the ARC failure response indicates a definitive,
        # non-recoverable rejection. Requires data to be present
        # (transport errors are always transient).
        def terminal_failure?(response)
          return false unless response.data

          terminal_status?(response.data['txStatus'], response.data['extraInfo'])
        end

        # True when the response is Arcade's 503 backpressure signal
        # (validator queue full, Retry-After header). The Arcade
        # SDK protocol returns +http_success: false+ with the original
        # 503 response attached, so the HTTP code is the discriminator.
        # ARC itself does not currently return 503 in normal operation,
        # but treating any 503 as backpressure costs nothing and matches
        # the plan §4.2 dispatch table.
        def backpressure?(response)
          response.code.to_s == '503'
        end
      end
    end
  end
end
