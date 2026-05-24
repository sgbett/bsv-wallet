# frozen_string_literal: true

require 'omq'

module BSV
  module Wallet
    class Engine
      # Background broadcast handler -- logical model for walletd.
      #
      # Owns OMQ sockets for background work (PULL) and inline
      # request-reply (REP). Processes pending broadcasts by calling
      # Services and recording results in Store.
      class Broadcast
        include OmqSupport

        # ARC txStatus values indicating the transaction was accepted by the network.
        ACCEPTED_STATUSES = %w[SEEN_ON_NETWORK ACCEPTED_BY_NETWORK MINED IMMUTABLE].freeze

        # ARC txStatus values indicating a definitive, non-recoverable rejection.
        # Intentionally excludes MINED_IN_STALE_BLOCK (transient -- the tx is
        # valid, just on a stale chain; daemon re-discovers per #126's self-heal
        # narrative).
        TERMINAL_STATUSES = %w[REJECTED DOUBLE_SPEND_ATTEMPTED MALFORMED].freeze

        def initialize(store:, services:)
          @store = store
          @services = services
        end

        # Background queue -- fire-and-forget processing.
        # Binds a PULL socket; the Scheduler pushes action IDs here.
        def pull!(task:)
          task.async do
            pull = bind_or_die('broadcast_push') { OMQ::PULL.bind('inproc://broadcasts.pull') }
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

        # Inline request-reply -- caller sends action_id, gets tx_status back.
        def reply!(task:)
          task.async do
            rep = bind_or_die('broadcast_push') { OMQ::REP.bind('inproc://broadcasts.rep') }
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

        # Process a single action -- submit if not yet broadcast, poll status if already broadcast.
        #
        # Emits exactly one task.dispatched on entry, then exactly one of
        # task.succeeded / task.failed / task.aborted / task.skipped.
        def process(action_id)
          BSV::Wallet.emit('task.dispatched', task: 'broadcast_push', id: action_id)
          started_at = Time.now

          action = @store.find_action(id: action_id)
          unless action
            BSV::Wallet.emit('task.skipped', task: 'broadcast_push', id: action_id, reason: :action_not_found)
            return
          end
          unless action[:raw_tx]
            BSV::Wallet.emit('task.skipped', task: 'broadcast_push', id: action_id, reason: :no_raw_tx)
            return
          end

          status = @store.broadcast_status(action_id: action_id)

          # NOTE: only the poll branch is reachable via Scheduler discovery --
          # Store#pending_broadcasts filters to stale rows with broadcast_at
          # set. The submit branch fires when callers invoke process directly
          # (e.g. the inline reply! socket). Store#pending_submissions is the
          # follow-up that closes the discovery gap.
          if status && status[:broadcast_at]
            poll_status(action_id, action, status: status, started_at: started_at)
          else
            submit(action_id, action, started_at: started_at)
          end
        end

        # Discovery query -- returns action IDs whose broadcasts are stale
        # and non-terminal (eligible for status polling). Pre-broadcast
        # actions (no Broadcasts row, or broadcast_at IS NULL) are not
        # returned here; submission discovery is a separate concern.
        def self.pending(store, limit: 10)
          store.pending_broadcasts(limit: limit).map { |b| b[:action_id] }
        end

        private

        # Initial broadcast -- submit raw_tx to ARC.
        def submit(action_id, action, started_at:)
          response = @services.call(:broadcast, action[:raw_tx])
          latency_ms = ((Time.now - started_at) * 1000).round

          if response.http_success?
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
            BSV::Wallet.emit('task.succeeded',
                             task: 'broadcast_push', id: action_id,
                             latency_ms: latency_ms,
                             outcome: categorize_outcome(data[:tx_status]))
            updated
          elsif terminal_failure?(response)
            @store.abort_action(action_id: action_id)
            BSV::Wallet.emit('task.aborted',
                             task: 'broadcast_push', id: action_id,
                             reason: categorize_reason(response),
                             arc_status: response.data['txStatus'])
            nil
          else
            BSV::Wallet.emit('task.failed',
                             task: 'broadcast_push', id: action_id,
                             latency_ms: latency_ms,
                             reason: categorize_reason(response))
            @store.broadcast_status(action_id: action_id)
          end
        end

        # Status poll -- query ARC for current tx status.
        #
        # Per the analyst's Task C option C-1, the poll path aborts on a
        # terminal txStatus (REJECTED, DOUBLE_SPEND_ATTEMPTED, MALFORMED,
        # or ORPHAN in extraInfo). Store#abort_action is a no-op once a
        # broadcast row exists, so terminal aborts go through
        # Store#fail_broadcast_action which deletes both the broadcast row
        # and the action (cascading to outputs / inputs / spendable rows
        # so locked UTXOs are released for re-use).
        def poll_status(action_id, action, status:, started_at:)
          unless action[:wtxid]
            BSV::Wallet.emit('task.skipped', task: 'broadcast_push', id: action_id, reason: :no_wtxid)
            return status
          end

          dtxid = action[:wtxid].reverse.unpack1('H*')
          response = @services.call(:get_tx_status, txid: dtxid)
          latency_ms = ((Time.now - started_at) * 1000).round

          if response.http_success?
            data = response.data
            if terminal_status?(data[:tx_status], data[:extra_info])
              @store.fail_broadcast_action(action_id: action_id)
              BSV::Wallet.emit('task.aborted',
                               task: 'broadcast_push', id: action_id,
                               reason: categorize_terminal_reason(data[:tx_status], data[:extra_info]),
                               arc_status: data[:tx_status])
              return nil
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
            BSV::Wallet.emit('task.succeeded',
                             task: 'broadcast_push', id: action_id,
                             latency_ms: latency_ms,
                             outcome: categorize_outcome(data[:tx_status]))
            updated
          else
            BSV::Wallet.emit('task.failed',
                             task: 'broadcast_push', id: action_id,
                             latency_ms: latency_ms,
                             reason: categorize_reason(response))
            status
          end
        end

        # Categorize a successful ARC txStatus into an outcome bucket.
        def categorize_outcome(tx_status)
          status = tx_status.to_s.upcase
          if ACCEPTED_STATUSES.include?(status)
            :accepted
          elsif TERMINAL_STATUSES.include?(status)
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
          return :malformed if status == 'MALFORMED'
          return :policy_violation if status == 'REJECTED'
          return :policy_violation if status.include?('ORPHAN') || info.include?('ORPHAN')

          :unknown
        end

        # True when the txStatus + extraInfo indicate a definitive,
        # non-recoverable rejection. Used by both submit (failure path)
        # and poll (success path with terminal txStatus).
        def terminal_status?(tx_status, extra_info = nil)
          status = tx_status.to_s.upcase
          return true if TERMINAL_STATUSES.include?(status)

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
      end
    end
  end
end
