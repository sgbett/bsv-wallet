# frozen_string_literal: true

require_relative 'shared_context'

require 'logger'

RSpec.describe BSV::Wallet::Store::EventApplicator, :store do
  let(:applicator) { described_class.new(store: store) }

  let(:action) do
    BSV::Wallet::Store::Models::Action.create(
      description: 'test action 12345',
      nlocktime: 0,
      wtxid: SecureRandom.random_bytes(32),
      raw_tx: SecureRandom.random_bytes(100)
    )
  end

  let(:broadcast) do
    BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')
  end

  def event_for(action, tx_status:, **overrides)
    {
      wtxid: String.new(action.wtxid, encoding: Encoding::BINARY),
      tx_status: tx_status,
      status: 200,
      block_hash: nil,
      block_height: nil,
      merkle_path: nil,
      extra_info: nil,
      competing_txs: nil
    }.merge(overrides)
  end

  describe '#apply' do
    # --- L2.1 ---
    it 'records the tx_status on SEEN_ON_NETWORK' do
      broadcast

      applicator.apply(event_for(action, tx_status: 'SEEN_ON_NETWORK'))

      expect(broadcast.reload.tx_status).to eq('SEEN_ON_NETWORK')
    end

    # --- L2.2 ---
    it 'cascade-unwinds via reject_action on REJECTED' do
      broadcast

      applicator.apply(event_for(action, tx_status: 'REJECTED'))

      # reject_action ran: the action (and its cascading broadcast row) is
      # gone, rather than a stranded REJECTED tx_status the resolution loop
      # would never rediscover.
      expect(BSV::Wallet::Store::Models::Action[action.id]).to be_nil
      expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)).to be_nil
    end

    # --- L2.3 ---
    it 'cascade-unwinds on DOUBLE_SPEND_ATTEMPTED (same as REJECTED) and logs the distinct status' do
      broadcast
      logger = instance_double(Logger, info: nil, warn: nil, error: nil)
      allow(BSV).to receive(:logger).and_return(logger)

      applicator.apply(event_for(action, tx_status: 'DOUBLE_SPEND_ATTEMPTED'))

      expect(BSV::Wallet::Store::Models::Action[action.id]).to be_nil
      expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)).to be_nil
      # Telemetry: the cascade deletes the broadcasts row, so the granular
      # status only survives in the log line emitted before reject_action.
      expect(logger).to have_received(:info) do |&block|
        expect(block.call).to include('DOUBLE_SPEND_ATTEMPTED')
      end
    end

    # --- L2.4 ---
    it 'bumps retry_count on CannotRejectInternalActionError, no crash' do
      broadcast
      allow(store).to receive(:reject_action)
        .and_raise(BSV::Wallet::CannotRejectInternalActionError.new(action.id))
      allow(store).to receive(:increment_broadcast_retry)

      expect { applicator.apply(event_for(action, tx_status: 'REJECTED')) }
        .not_to raise_error
      expect(store).to have_received(:increment_broadcast_retry).with(action_id: action.id)
    end

    # --- L2.5 ---
    it 'logs and returns on CannotRejectAcceptedActionError, no retry' do
      broadcast
      allow(store).to receive(:reject_action)
        .and_raise(BSV::Wallet::CannotRejectAcceptedActionError.new(action.id, 'MINED'))
      allow(store).to receive(:increment_broadcast_retry)
      logger = instance_double(Logger, info: nil, warn: nil, error: nil)
      allow(BSV).to receive(:logger).and_return(logger)

      expect { applicator.apply(event_for(action, tx_status: 'REJECTED')) }
        .not_to raise_error
      # Accepted-divergence is not transient -- log for operator investigation,
      # DO NOT bump retry_count (re-org case; retrying never helps).
      expect(store).not_to have_received(:increment_broadcast_retry)
      expect(logger).to have_received(:error)
    end

    # --- L2.6 ---
    it 'logs and skips on unknown wtxid, no crash' do
      unknown_wtxid = SecureRandom.random_bytes(32)
      event = {
        wtxid: unknown_wtxid, tx_status: 'SEEN_ON_NETWORK', status: 200,
        block_hash: nil, block_height: nil, merkle_path: nil,
        extra_info: nil, competing_txs: nil
      }
      logger = instance_double(Logger, info: nil, warn: nil, error: nil)
      allow(BSV).to receive(:logger).and_return(logger)
      allow(store).to receive(:record_broadcast_result)
      allow(store).to receive(:reject_action)

      expect { applicator.apply(event) }.not_to raise_error
      expect(store).not_to have_received(:record_broadcast_result)
      expect(store).not_to have_received(:reject_action)
      expect(logger).to have_received(:warn)
    end

    # --- L2.7 ---
    it 'is idempotent on current state: applying REJECTED twice does not double-unwind' do
      broadcast

      applicator.apply(event_for(action, tx_status: 'REJECTED'))
      expect(BSV::Wallet::Store::Models::Action[action.id]).to be_nil

      # Second apply finds nothing (action gone) and follows the unknown-wtxid
      # log+skip path. No crash, no double-unwind side effects to observe.
      expect { applicator.apply(event_for(action, tx_status: 'REJECTED')) }
        .not_to raise_error
    end

    it 'is idempotent across SEEN then REJECTED (same end-state as REJECTED alone)' do
      broadcast

      applicator.apply(event_for(action, tx_status: 'SEEN_ON_NETWORK'))
      expect(broadcast.reload.tx_status).to eq('SEEN_ON_NETWORK')

      # SEEN_ON_NETWORK is in ArcStatus::ACCEPTED, so reject_action will
      # raise CannotRejectAcceptedActionError -- the no-invalid-state
      # invariant kicks in. The action survives; no retry bump.
      allow(store).to receive(:increment_broadcast_retry)
      logger = instance_double(Logger, info: nil, warn: nil, error: nil)
      allow(BSV).to receive(:logger).and_return(logger)

      applicator.apply(event_for(action, tx_status: 'REJECTED'))

      expect(BSV::Wallet::Store::Models::Action[action.id]).not_to be_nil
      expect(store).not_to have_received(:increment_broadcast_retry)
      expect(logger).to have_received(:error)
    end
  end
end
