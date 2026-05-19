# frozen_string_literal: true

# L2c CLI specs — tests each porcelain tool in isolation.
#
# These specs verify argument parsing, output format, error handling,
# and exit codes by running bin/ scripts via Open3.capture3.
# Argument-validation paths exit before CLI.boot, so no database is needed.

require 'open3'
require 'json'

RSpec.describe 'Porcelain CLI tools' do # rubocop:disable RSpec/DescribeClass
  let(:bin_dir) { File.expand_path('../../bin', __dir__) }
  let(:valid_identity_key) { "02#{'ab' * 32}" }
  let(:invalid_prefix_key) { "04#{'ab' * 32}" }

  def run_tool(name, *args, stdin_data: nil)
    cmd = ['ruby', File.join(bin_dir, name)] + args
    Open3.capture3(*cmd, stdin_data: stdin_data)
  end

  # --- bin/create ---

  describe 'bin/create' do
    it 'shows usage on stderr and exits non-zero with no args' do
      stdout, stderr, status = run_tool('create')

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage:')
      expect(stdout).to be_empty
    end

    it 'shows usage when only wallet is provided' do
      _stdout, stderr, status = run_tool('create', 'alice')

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage:')
    end

    it 'shows usage when only wallet and identity_key are provided' do
      _stdout, stderr, status = run_tool('create', 'alice', valid_identity_key)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage:')
    end

    it 'rejects zero satoshis' do
      _stdout, stderr, status = run_tool('create', 'alice', valid_identity_key, '0')

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage:')
    end

    it 'rejects invalid identity key (too short)' do
      _stdout, stderr, status = run_tool('create', 'alice', 'deadbeef', '1000')

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Invalid identity key')
    end

    it 'rejects identity key with invalid prefix' do
      _stdout, stderr, status = run_tool('create', 'alice', invalid_prefix_key, '1000')

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Invalid identity key')
    end
  end

  # --- bin/import ---

  describe 'bin/import' do
    it 'shows usage on stderr and exits non-zero with no args' do
      stdout, stderr, status = run_tool('import')

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage:')
      expect(stdout).to be_empty
    end
  end

  # --- bin/balance ---

  describe 'bin/balance' do
    it 'exits non-zero without wallet env vars' do
      _stdout, stderr, status = run_tool('balance', 'nonexistent')

      expect(status.exitstatus).to eq(1)
      expect(stderr).not_to be_empty
    end
  end

  # --- bin/receive ---

  describe 'bin/receive' do
    it 'aborts when stdin is a TTY (no piped data)' do
      # When run without piped input and stdin is a TTY, receive aborts.
      # Open3 provides a pipe (not a TTY), so we test the empty-stdin path.
      _stdout, stderr, status = run_tool('receive', 'alice', stdin_data: '')

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Empty stdin')
    end

    it 'aborts when stdin contains invalid JSON' do
      _stdout, stderr, status = run_tool('receive', 'alice', stdin_data: 'not json')

      expect(status.exitstatus).to eq(1)
      expect(stderr).not_to be_empty
    end

    it 'aborts when envelope is missing "beef" key' do
      envelope = JSON.generate({ sender_identity_key: valid_identity_key, outputs: [] })
      _stdout, stderr, status = run_tool('receive', 'alice', stdin_data: envelope)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('beef')
    end

    it 'aborts when envelope is missing "sender_identity_key"' do
      envelope = JSON.generate({ beef: 'a' * 64, outputs: [] })
      _stdout, stderr, status = run_tool('receive', 'alice', stdin_data: envelope)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('sender_identity_key')
    end

    it 'aborts when envelope is missing "outputs"' do
      envelope = JSON.generate({ beef: 'a' * 64, sender_identity_key: valid_identity_key })
      _stdout, stderr, status = run_tool('receive', 'alice', stdin_data: envelope)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('outputs')
    end
  end

  # --- bin/send (deprecated) ---

  describe 'bin/send' do
    it 'warns about deprecation' do
      # bin/send prints a deprecation warning before doing anything else.
      # It will eventually fail due to missing args/env, but the warning
      # should appear regardless.
      _stdout, stderr, _status = run_tool('send')

      expect(stderr).to include('DEPRECATED')
      expect(stderr).to include('bin/create')
    end
  end
end
