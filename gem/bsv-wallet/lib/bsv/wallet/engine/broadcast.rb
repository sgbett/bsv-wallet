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
            @store.record_broadcast_result(
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
          elsif terminal_failure?(response)
            @store.abort_action(action_id: action_id)
            BSV::Wallet.emit('task.aborted',
                             task: 'broadcast_push', id: action_id,
                             reason: categorize_reason(response),
                             arc_status: response.data['txStatus'])
          else
            BSV::Wallet.emit('task.failed',
                             task: 'broadcast_push', id: action_id,
                             latency_ms: latency_ms,
                             reason: categorize_reason(response))
          end

          @store.broadcast_status(action_id: action_id)
        end

        # Status poll -- query ARC for current tx status.
        #
        # Per the analyst's C-2 recommendation, the poll path never aborts.
        # An ARC-reported terminal status (REJECTED, DOUBLE_SPEND_ATTEMPTED,
        # MALFORMED) is recorded via record_broadcast_result and surfaces as
        # task.succeeded outcome=:rejected -- operators reconcile via the
        # event stream rather than via Store#abort_action, whose semantics
        # are not well-defined for post-broadcast aborts.
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
            @store.record_broadcast_result(
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
          else
            BSV::Wallet.emit('task.failed',
                             task: 'broadcast_push', id: action_id,
                             latency_ms: latency_ms,
                             reason: categorize_reason(response))
          end

          @store.broadcast_status(action_id: action_id)
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
            extra_info = response.data['extraInfo'].to_s.upcase

            return :double_spend if tx_status == 'DOUBLE_SPEND_ATTEMPTED'
            return :malformed if tx_status == 'MALFORMED'
            return :stale_beef if tx_status == 'MINED_IN_STALE_BLOCK'
            return :policy_violation if tx_status == 'REJECTED'
            return :policy_violation if tx_status.include?('ORPHAN') || extra_info.include?('ORPHAN')

            :unknown
          elsif response.retryable?
            response.code.to_i == 429 ? :rate_limited : :transport_error
          else
            :malformed
          end
        end

        # True when the ARC response indicates a definitive, non-recoverable
        # rejection. Requires data to be present (transport errors are always
        # transient) and the txStatus to be in our terminal set or carry the
        # ORPHAN marker.
        def terminal_failure?(response)
          return false unless response.data

          tx_status = response.data['txStatus'].to_s.upcase
          return true if TERMINAL_STATUSES.include?(tx_status)

          extra_info = response.data['extraInfo'].to_s.upcase
          return true if tx_status.include?('ORPHAN') || extra_info.include?('ORPHAN')

          false
        end
      end
    end
  end
end
