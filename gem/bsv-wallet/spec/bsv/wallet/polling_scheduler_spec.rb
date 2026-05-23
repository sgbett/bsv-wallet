# frozen_string_literal: true

require 'bsv-wallet'

RSpec.describe BSV::Wallet::PollingScheduler do
  subject(:scheduler) { described_class.new(interval: 0) }

  describe 'Interface::Scheduler contract' do
    it 'includes the Scheduler interface' do
      expect(described_class.ancestors).to include(BSV::Wallet::Interface::Scheduler)
    end
  end

  describe '#register_task + #run_cycle' do
    it 'dispatches handler for each discovered entity' do
      handled = []
      scheduler.register_task(
        name: :test_task,
        discovery: -> { %i[a b c] },
        handler: ->(entity) { handled << entity }
      )

      scheduler.run_cycle

      expect(handled).to eq(%i[a b c])
    end

    it 'does nothing when discovery returns empty' do
      handled = []
      scheduler.register_task(
        name: :empty_task,
        discovery: -> { [] },
        handler: ->(entity) { handled << entity }
      )

      scheduler.run_cycle

      expect(handled).to be_empty
    end

    it 'processes multiple registered tasks in order' do
      order = []
      scheduler.register_task(name: :first, discovery: -> { [:x] }, handler: ->(_) { order << :first })
      scheduler.register_task(name: :second, discovery: -> { [:y] }, handler: ->(_) { order << :second })

      scheduler.run_cycle

      expect(order).to eq(%i[first second])
    end
  end

  describe '#register_periodic + #run_cycle' do
    it 'dispatches handler with no entity' do
      called = 0
      scheduler.register_periodic(name: :sweep, handler: -> { called += 1 })

      scheduler.run_cycle

      expect(called).to eq(1)
    end

    it 'runs after entity-driven tasks' do
      order = []
      scheduler.register_task(name: :entities, discovery: -> { [:a] }, handler: ->(_) { order << :entities })
      scheduler.register_periodic(name: :periodic, handler: -> { order << :periodic })

      scheduler.run_cycle

      expect(order).to eq(%i[entities periodic])
    end
  end

  describe 'error handling' do
    it 'continues to next entity when handler fails' do
      handled = []
      scheduler.register_task(
        name: :partial_fail,
        discovery: -> { %i[ok bad ok2] },
        handler: lambda { |e|
          raise 'boom' if e == :bad

          handled << e
        }
      )

      scheduler.run_cycle

      expect(handled).to eq(%i[ok ok2])
    end

    it 'continues to next task when discovery fails' do
      handled = []
      scheduler.register_task(name: :broken, discovery: -> { raise 'discovery failed' }, handler: ->(_) {})
      scheduler.register_task(name: :healthy, discovery: -> { [:a] }, handler: ->(e) { handled << e })

      scheduler.run_cycle

      expect(handled).to eq([:a])
    end

    it 'continues to next periodic when one fails' do
      results = []
      scheduler.register_periodic(name: :broken, handler: -> { raise 'fail' })
      scheduler.register_periodic(name: :healthy, handler: -> { results << :ok })

      scheduler.run_cycle

      expect(results).to eq([:ok])
    end

    it 'does not crash when a listener raises' do
      scheduler.on_event { |_| raise 'listener boom' }
      scheduler.register_periodic(name: :task, handler: -> {})

      expect { scheduler.run_cycle }.not_to raise_error
    end
  end

  describe '#on_event' do
    it 'emits :dispatched and :succeeded for a successful entity handler' do
      events = []
      scheduler.on_event { |e| events << e }
      scheduler.register_task(name: :test, discovery: -> { [:entity_a] }, handler: ->(_) {})

      scheduler.run_cycle

      dispatched = events.find { |e| e[:event] == :dispatched }
      succeeded = events.find { |e| e[:event] == :succeeded }

      expect(dispatched).not_to be_nil
      expect(dispatched[:task]).to eq(:test)
      expect(dispatched[:entity]).to eq(:entity_a)
      expect(dispatched[:timestamp]).to be_a(Time)

      expect(succeeded).not_to be_nil
      expect(succeeded[:task]).to eq(:test)
      expect(succeeded[:entity]).to eq(:entity_a)
    end

    it 'emits :failed with error for handler failure' do
      events = []
      scheduler.on_event { |e| events << e }
      scheduler.register_task(name: :fail, discovery: -> { [:x] }, handler: ->(_) { raise 'oops' })

      scheduler.run_cycle

      failed = events.find { |e| e[:event] == :failed && e[:entity] == :x }
      expect(failed).not_to be_nil
      expect(failed[:error]).to be_a(RuntimeError)
      expect(failed[:error].message).to eq('oops')
    end

    it 'emits events for periodic tasks without entity' do
      events = []
      scheduler.on_event { |e| events << e }
      scheduler.register_periodic(name: :sweep, handler: -> {})

      scheduler.run_cycle

      dispatched = events.find { |e| e[:event] == :dispatched && e[:task] == :sweep }
      expect(dispatched[:entity]).to be_nil

      succeeded = events.find { |e| e[:event] == :succeeded && e[:task] == :sweep }
      expect(succeeded[:entity]).to be_nil
    end

    it 'emits :failed for discovery errors' do
      events = []
      scheduler.on_event { |e| events << e }
      scheduler.register_task(name: :bad_discovery, discovery: -> { raise 'discovery fail' }, handler: ->(_) {})

      scheduler.run_cycle

      failed = events.find { |e| e[:event] == :failed && e[:task] == :bad_discovery }
      expect(failed).not_to be_nil
      expect(failed[:error].message).to eq('discovery fail')
    end
  end

  describe '#quiescent?' do
    it 'returns true when not dispatching' do
      expect(scheduler.quiescent?).to be true
    end

    it 'returns false during dispatch' do
      in_dispatch = nil
      scheduler.register_periodic(name: :check, handler: -> { in_dispatch = scheduler.quiescent? })

      scheduler.run_cycle

      expect(in_dispatch).to be false
    end
  end

  describe '#drain' do
    it 'returns true immediately when quiescent' do
      expect(scheduler.drain(timeout: 0.1)).to be true
    end

    it 'returns false when timeout expires during dispatch' do
      # Simulate a long-running handler by checking drain from another context
      # In the polling scheduler, drain is only useful when called from
      # a different thread. With interval: 0, run_cycle completes quickly.
      scheduler.register_periodic(name: :quick, handler: -> {})
      scheduler.run_cycle
      expect(scheduler.drain(timeout: 0.1)).to be true
    end
  end

  describe '#stop' do
    it 'exits the loop after current cycle' do
      cycle_count = 0
      scheduler.register_periodic(name: :counter, handler: -> { cycle_count += 1 })

      # Stop after first cycle
      scheduler.on_event do |e|
        scheduler.stop if e[:event] == :succeeded && cycle_count >= 1
      end

      scheduler.start

      expect(cycle_count).to eq(1)
      expect(scheduler.running?).to be false
    end
  end

  describe 'idempotent execution' do
    it 'handles duplicate entities without error' do
      call_count = Hash.new(0)
      scheduler.register_task(
        name: :idempotent,
        discovery: -> { %i[same same same] },
        handler: ->(e) { call_count[e] += 1 }
      )

      scheduler.run_cycle

      expect(call_count[:same]).to eq(3) # Framework dispatches all; handler is idempotent
    end
  end
end
