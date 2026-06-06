# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'

RSpec.describe BSV::Wallet do # rubocop:disable RSpec/SpecFilePathFormat
  let(:buffer) { StringIO.new }
  let(:logger) { Logger.new(buffer) }

  around do |example|
    original_logger = BSV.logger
    BSV.logger = logger
    example.run
  ensure
    BSV.logger = original_logger
  end

  def logged_output
    buffer.string
  end

  describe '.emit' do
    it 'writes a structured event line at :info level' do
      described_class.emit('foo', a: 1, b: 'x')

      expect(logged_output).to include('[event] foo a=1 b=x')
      expect(logged_output).to include('INFO')
    end

    it 'emits name only with no trailing space when payload is empty' do
      described_class.emit('foo')

      expect(logged_output).to include('[event] foo')
      expect(logged_output).not_to include('[event] foo ')
    end

    it 'skips nil values' do
      described_class.emit('foo', a: 1, b: nil, c: 3)

      expect(logged_output).to include('[event] foo a=1 c=3')
      expect(logged_output).not_to include('b=')
    end

    it 'quotes values containing whitespace' do
      described_class.emit('foo', reason: 'something with spaces')

      expect(logged_output).to include('reason="something with spaces"')
    end

    it 'escapes embedded double quotes in values' do
      described_class.emit('foo', msg: 'say "hello" now')

      expect(logged_output).to include('msg="say \\"hello\\" now"')
    end

    it 'is a no-op when BSV.logger is nil' do
      BSV.logger = nil

      expect { described_class.emit('foo', a: 1) }.not_to raise_error
    end

    context 'with BSV::Wallet.event_log configured' do
      let(:event_buffer) { StringIO.new }
      let(:event_log) { Logger.new(event_buffer) }

      around do |example|
        original = described_class.event_log
        described_class.event_log = event_log
        example.run
      ensure
        described_class.event_log = original
      end

      def event_log_output
        event_buffer.string
      end

      it 'writes the canonical [event] line to event_log alongside BSV.logger' do
        described_class.emit('task.succeeded', task: 'broadcast_push', id: 42)

        expect(event_log_output).to include('[event] task.succeeded task=broadcast_push id=42')
        expect(logged_output).to include('[event] task.succeeded task=broadcast_push id=42')
      end

      it 'event_log lines start with ISO-8601 timestamp (no Logger prefix junk)' do
        described_class.emit('foo', a: 1)

        # Format: 2026-05-28T12:34:56.789Z [event] foo a=1
        expect(event_log_output).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z \[event\] foo a=1\n\z/)
      end

      it 'event_log lines have no severity / pid / progname prefix' do
        described_class.emit('foo')

        # Standard Logger format would include "INFO -- :" or similar.
        expect(event_log_output).not_to include('INFO')
        expect(event_log_output).not_to match(/--\s*:/)
      end

      it 'still emits when BSV.logger is nil but event_log is set' do
        BSV.logger = nil
        described_class.emit('foo', a: 1)

        expect(event_log_output).to include('[event] foo a=1')
      end
    end

    context 'event_log= setter' do
      it 'returns the assigned logger' do
        log = Logger.new(StringIO.new)
        expect(described_class.event_log = log).to eq(log)
      ensure
        described_class.event_log = nil
      end

      it 'auto-applies the canonical formatter to the assigned logger' do
        log = Logger.new(StringIO.new)
        described_class.event_log = log
        expect(log.formatter).to eq(BSV::Wallet::EVENT_LOG_FORMATTER)
      ensure
        described_class.event_log = nil
      end

      it 'accepts nil to disable the sink' do
        described_class.event_log = Logger.new(StringIO.new)
        described_class.event_log = nil
        expect(described_class.event_log).to be_nil
      end
    end

    it 'stringifies symbol values via to_s' do
      described_class.emit('foo', outcome: :accepted)

      expect(logged_output).to include('outcome=accepted')
    end

    it 'emits empty-string values as key=' do
      described_class.emit('foo', name: '')

      expect(logged_output).to include('name=')
      expect(logged_output).not_to include('name=""')
    end

    it 'does not raise on hash values' do
      described_class.emit('foo', data: { a: 1 })

      expect(logged_output).to include('data=')
    end

    it 'does not raise on array values' do
      described_class.emit('foo', items: [1, 2, 3])

      expect(logged_output).to include('items=')
    end
  end

  describe '.format_field' do
    it 'returns nil for nil values' do
      expect(described_class.format_field(:key, nil)).to be_nil
    end

    it 'formats a simple key=value pair' do
      expect(described_class.format_field(:count, 42)).to eq('count=42')
    end

    it 'quotes values with whitespace' do
      expect(described_class.format_field(:reason, 'has space')).to eq('reason="has space"')
    end

    it 'escapes embedded double quotes' do
      expect(described_class.format_field(:msg, 'say "hi"')).to eq('msg="say \\"hi\\""')
    end
  end
end
