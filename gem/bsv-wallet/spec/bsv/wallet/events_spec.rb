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
      expect(logged_output).to match(/INFO/)
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
