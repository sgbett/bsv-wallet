# frozen_string_literal: true

# L2c CLI specs — tests each porcelain tool in isolation.
#
# These specs verify argument parsing, output format, error handling,
# and exit codes by running bin/ scripts via Open3.capture3.
# Argument-validation paths exit before CLI.boot, so no database is needed.

require 'open3'
require 'json'
require 'tmpdir'

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

  # --- bin/reject ---

  describe 'bin/reject' do
    it 'aborts with usage when --action-id is missing' do
      _stdout, stderr, status = run_tool('reject', 'alice')

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Missing --action-id')
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

  # --- bin/transmit ---

  describe 'bin/transmit' do
    let(:endpoint) { 'https://peer.example/internalize' }
    let(:dtxid) { 'aa' * 32 }
    let(:full_envelope) do
      JSON.generate(
        beef: 'ff' * 16,
        sender_identity_key: valid_identity_key,
        outputs: [{ vout: 0, satoshis: 500, derivation_prefix: 'p', derivation_suffix: '1' }],
        dtxid: dtxid
      )
    end

    it 'aborts when --to is missing' do
      _stdout, stderr, status = run_tool('transmit', 'alice', '--endpoint', endpoint,
                                         stdin_data: full_envelope)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Missing --to')
    end

    it 'aborts when --endpoint is missing' do
      _stdout, stderr, status = run_tool('transmit', 'alice', '--to', valid_identity_key,
                                         stdin_data: full_envelope)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Missing --endpoint')
    end

    it 'rejects an invalid --to value (wrong length)' do
      _stdout, stderr, status = run_tool('transmit', 'alice',
                                         '--to', 'deadbeef',
                                         '--endpoint', endpoint,
                                         stdin_data: full_envelope)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Invalid identity key')
    end

    it 'rejects an invalid --to value (wrong prefix)' do
      _stdout, stderr, status = run_tool('transmit', 'alice',
                                         '--to', invalid_prefix_key,
                                         '--endpoint', endpoint,
                                         stdin_data: full_envelope)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Invalid identity key')
    end

    it 'aborts when stdin is empty' do
      _stdout, stderr, status = run_tool('transmit', 'alice',
                                         '--to', valid_identity_key,
                                         '--endpoint', endpoint,
                                         stdin_data: '')

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Empty stdin')
    end

    it 'aborts when stdin contains malformed JSON' do
      _stdout, stderr, status = run_tool('transmit', 'alice',
                                         '--to', valid_identity_key,
                                         '--endpoint', endpoint,
                                         stdin_data: 'not json')

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Invalid JSON')
    end

    it 'aborts when envelope is missing "dtxid"' do
      envelope = JSON.generate(beef: 'ff' * 16,
                               sender_identity_key: valid_identity_key,
                               outputs: [])
      _stdout, stderr, status = run_tool('transmit', 'alice',
                                         '--to', valid_identity_key,
                                         '--endpoint', endpoint,
                                         stdin_data: envelope)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('dtxid')
    end

    it 'aborts when envelope is missing "outputs"' do
      envelope = JSON.generate(beef: 'ff' * 16,
                               sender_identity_key: valid_identity_key,
                               dtxid: dtxid)
      _stdout, stderr, status = run_tool('transmit', 'alice',
                                         '--to', valid_identity_key,
                                         '--endpoint', endpoint,
                                         stdin_data: envelope)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('outputs')
    end

    it 'aborts when envelope is missing "sender_identity_key"' do
      envelope = JSON.generate(beef: 'ff' * 16, outputs: [], dtxid: dtxid)
      _stdout, stderr, status = run_tool('transmit', 'alice',
                                         '--to', valid_identity_key,
                                         '--endpoint', endpoint,
                                         stdin_data: envelope)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('sender_identity_key')
    end

    # Happy path runs bin/transmit in a subprocess with a stubbed
    # +BSV::Wallet::CLI.boot+ so we can assert end-to-end behaviour
    # (transmit invocation kwargs, stdout JSON shape, stderr redaction)
    # without touching a real wallet, DB, or peer endpoint. Mirrors the
    # subprocess-stub shape from +spec/bin/boot_spec.rb+.
    context 'happy path (stubbed boot)' do
      let(:credentialled_endpoint) { 'https://user:secret@peer.example.com/path?token=xyz' }

      def run_stubbed_transmit(envelope:, counterparty:, endpoint:, transmission_id: 42)
        bin_path = File.expand_path('../../bin/transmit', __dir__)
        lib_path = File.expand_path('../../lib', __dir__)

        # In-process stub: replace +BSV::Wallet::CLI.boot+ with a fake
        # whose +engine.transmission.transmit+ returns a delivered
        # +PeerDelivery::Result+. Then load the bin script (it requires
        # bsv/wallet/cli, then runs at top level).
        ruby_src = <<~RUBY
          $LOAD_PATH.unshift(#{lib_path.inspect})
          require 'bsv-wallet'
          require 'bsv/wallet/cli'
          require 'bsv/network/peer_delivery'

          # Capture the transmit kwargs so assertions can inspect them.
          captured = {}

          fake_delivery = BSV::Network::PeerDelivery::Result.new(
            outcome: :delivered,
            wtxid: 'aa' * 32,
            http_status: 200
          )

          fake_action = { id: 7, raw_tx: ('00' * 4).b }
          fake_store = Class.new do
            define_method(:find_action) { |**| fake_action }
          end.new

          fake_transmission = Class.new do
            define_method(:transmit) do |**kwargs|
              captured.merge!(kwargs)
              { transmission_id: #{transmission_id},
                beef: kwargs[:outputs].to_s.b,
                sent_wtxids: [('aa' * 32).b],
                outputs: kwargs[:outputs],
                sender_identity_key: kwargs[:sender_identity_key],
                delivery: fake_delivery }
            end
          end.new

          fake_engine = Class.new do
            define_method(:store) { fake_store }
            define_method(:transmission) { fake_transmission }
          end.new

          BSV::Wallet::CLI.define_singleton_method(:boot) do |**|
            { engine: fake_engine }
          end

          # Mirror argv as if exec'd: bin/transmit reads ARGV at top level
          ARGV.replace(#{['alice', '--to', counterparty, '--endpoint', endpoint].inspect})

          # Feed stdin
          require 'stringio'
          $stdin = StringIO.new(#{envelope.inspect})

          load #{bin_path.inspect}

          # Surface the captured kwargs on a dedicated channel so the spec
          # can inspect them without parsing the redacted stderr.
          File.write(ENV.fetch('CAPTURE_FILE'), captured.inspect)
        RUBY

        Dir.mktmpdir do |dir|
          capture_path = File.join(dir, 'captured.txt')
          env = { 'CAPTURE_FILE' => capture_path }
          stdout, stderr, status = Open3.capture3(env, 'ruby', '-e', ruby_src)
          captured = File.exist?(capture_path) ? eval(File.read(capture_path)) : nil # rubocop:disable Security/Eval
          yield(stdout, stderr, status, captured)
        end
      end

      it 'invokes engine.transmission.transmit with the envelope and CLI flags' do
        run_stubbed_transmit(envelope: full_envelope, counterparty: valid_identity_key,
                             endpoint: endpoint) do |stdout, stderr, status, captured|
          expect(status.exitstatus).to eq(0), "stderr:\n#{stderr}\nstdout:\n#{stdout}"
          expect(captured).to include(
            counterparty: valid_identity_key,
            action_id: 7,
            sender_identity_key: valid_identity_key,
            endpoint: endpoint
          )
          expect(captured[:outputs]).to be_an(Array)
        end
      end

      it 'emits a JSON result envelope on stdout with the transmission_id and dtxid' do
        run_stubbed_transmit(envelope: full_envelope, counterparty: valid_identity_key,
                             endpoint: endpoint) do |stdout, _stderr, _status, _captured|
          parsed = JSON.parse(stdout.lines.last)
          expect(parsed).to include(
            'transmission_id' => 42,
            'outcome' => 'delivered',
            'delivered' => true,
            'http_status' => 200,
            'dtxid' => dtxid
          )
        end
      end

      it 'includes dtxid as the primary log key on stderr' do
        run_stubbed_transmit(envelope: full_envelope, counterparty: valid_identity_key,
                             endpoint: endpoint) do |_stdout, stderr, _status, _captured|
          expect(stderr).to include("dtxid=#{dtxid}")
        end
      end

      # HLR #385 Security AC: the human-readable log line must NOT leak
      # full URLs (credentialled or otherwise), the BEEF body, or the
      # full counterparty pubkey. The summary surfaces (host only,
      # last 8 chars of counterparty, no BEEF).
      it 'redacts the full endpoint URL — host only, no scheme/path/credentials' do
        run_stubbed_transmit(envelope: full_envelope, counterparty: valid_identity_key,
                             endpoint: credentialled_endpoint) do |_stdout, stderr, _status, _captured|
          expect(stderr).not_to include(credentialled_endpoint)
          expect(stderr).not_to include('secret')
          expect(stderr).not_to include('user:secret')
          expect(stderr).not_to include('token=xyz')
          expect(stderr).to include('peer.example.com')
        end
      end

      it 'redacts the counterparty pubkey to its last 8 chars' do
        run_stubbed_transmit(envelope: full_envelope, counterparty: valid_identity_key,
                             endpoint: endpoint) do |_stdout, stderr, _status, _captured|
          expect(stderr).not_to include(valid_identity_key)
          expect(stderr).to include("...#{valid_identity_key[-8..]}")
        end
      end

      it 'never echoes the BEEF body to stderr (not even a prefix)' do
        # BEEF hex from full_envelope is 'ff' * 16 = 32 chars of 'ff'.
        run_stubbed_transmit(envelope: full_envelope, counterparty: valid_identity_key,
                             endpoint: endpoint) do |_stdout, stderr, _status, _captured|
          expect(stderr).not_to include('ff' * 16)
          expect(stderr).not_to match(/beef.*=.*[0-9a-f]{16,}/i)
        end
      end
    end
  end
end
