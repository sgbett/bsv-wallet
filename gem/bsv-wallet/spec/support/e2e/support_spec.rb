# frozen_string_literal: true

# Unit specs for the e2e harness's support modules. They live alongside
# the modules they cover (spec/support/e2e) and run in the normal bare
# +rspec+ suite — they exercise pure-Ruby helpers (derivation maths, file
# lifecycle, subprocess management) that need no BSV_WALLET_WIF_SDK or
# on-chain state.
#
# The on-chain harness itself is the sole occupant of spec/e2e
# (+broadcast_spec.rb+), loaded via +spec/e2e/spec_helper.rb+ and excluded
# from the bare run by the +--exclude-pattern+ in +.rspec+.

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require_relative 'wallet_derivation'
require_relative 'event_log'
require_relative 'daemon_supervisor'

# Three top-level describe blocks — one per support module — kept flat
# for navigability rather than nested under a single umbrella.
# rubocop:disable RSpec/MultipleDescribes

RSpec.describe E2E::WalletDerivation do
  let(:sdk_pk) { BSV::Primitives::PrivateKey.generate }
  let(:sdk_wif) { sdk_pk.to_wif }

  describe '.derive_wifs' do
    it 'derives the requested number of WIFs' do
      wifs = described_class.derive_wifs(sdk_wif: sdk_wif, count: 5)
      expect(wifs.length).to eq(5)
    end

    it 'is deterministic for a given sdk_wif' do
      a = described_class.derive_wifs(sdk_wif: sdk_wif, count: 3)
      b = described_class.derive_wifs(sdk_wif: sdk_wif, count: 3)
      expect(a).to eq(b)
    end

    it 'produces distinct WIFs across child indices' do
      wifs = described_class.derive_wifs(sdk_wif: sdk_wif, count: 5)
      expect(wifs.uniq.length).to eq(5)
    end

    it 'does not produce the parent WIF at any index' do
      wifs = described_class.derive_wifs(sdk_wif: sdk_wif, count: 5)
      expect(wifs).not_to include(sdk_wif)
    end

    it 'produces valid WIFs that round-trip through PrivateKey.from_wif' do
      wifs = described_class.derive_wifs(sdk_wif: sdk_wif, count: 5)
      wifs.each do |wif|
        expect { BSV::Primitives::PrivateKey.from_wif(wif) }.not_to raise_error
      end
    end
  end

  describe '.derive_by_name' do
    it 'maps WALLET_NAMES to derived WIFs in order' do
      mapping = described_class.derive_by_name(sdk_wif: sdk_wif)
      expect(mapping.keys).to eq(described_class::WALLET_NAMES)
      expect(mapping.values).to eq(described_class.derive_wifs(sdk_wif: sdk_wif))
    end

    it 'accepts a custom name list' do
      mapping = described_class.derive_by_name(sdk_wif: sdk_wif, names: %w[alpha beta])
      expect(mapping.keys).to eq(%w[alpha beta])
      expect(mapping.values.length).to eq(2)
    end
  end
end

RSpec.describe E2E::EventLog do
  let(:tmpdir) { Dir.mktmpdir('e2e_event_log_') }

  after do
    described_class.stop
    FileUtils.rm_rf(tmpdir) if File.directory?(tmpdir)
  end

  describe '.start' do
    it 'creates a logfile under the supplied directory' do
      path = described_class.start(dir: tmpdir)
      expect(File.exist?(path)).to be(true)
    end

    it 'routes BSV::Wallet.event_log to the new file' do
      path = described_class.start(dir: tmpdir)
      BSV::Wallet.emit('e2e.test', a: 1)
      expect(File.read(path)).to include('[event] e2e.test a=1')
    end

    it 'uses an ISO-8601 + millisecond + PID prefix in the filename' do
      path = described_class.start(dir: tmpdir)
      expect(File.basename(path)).to match(/\Ae2e-\d{8}T\d{6}\.\d{3}Z-\d+\.log\z/)
    end
  end

  describe '.stop' do
    it 'clears BSV::Wallet.event_log' do
      described_class.start(dir: tmpdir)
      described_class.stop
      expect(BSV::Wallet.event_log).to be_nil
    end

    it 'is a no-op when nothing was started' do
      expect { described_class.stop }.not_to raise_error
    end
  end
end

RSpec.describe E2E::DaemonSupervisor do
  # The supervisor spawns +bin/walletd+, which would try to connect to
  # Postgres and ARC. We stub Process.spawn to keep this test as a unit
  # test for the supervisor's lifecycle bookkeeping only.
  let(:tmpdir) { Dir.mktmpdir('e2e_supervisor_') }
  let(:supervisor) do
    described_class.new(
      wallet_names: %w[w1 w2],
      network: :mainnet,
      log_dir: tmpdir,
      shutdown_timeout: 0.5
    )
  end

  after { FileUtils.rm_rf(tmpdir) if File.directory?(tmpdir) }

  describe '#start_all' do
    it 'spawns one subprocess per wallet and records its pid' do
      allow(Process).to receive(:spawn).and_return(10, 11)
      result = supervisor.start_all
      expect(result.keys).to eq(%w[w1 w2])
      expect(result.values).to eq([10, 11])
    end

    it 'opens a per-wallet logfile under log_dir' do
      allow(Process).to receive(:spawn).and_return(10, 11)
      supervisor.start_all
      expect(supervisor.log_paths.keys).to eq(%w[w1 w2])
      supervisor.log_paths.each_value do |path|
        expect(File.dirname(path)).to eq(tmpdir)
        expect(File.exist?(path)).to be(true)
      end
    end

    it 'passes wallet name and network to walletd as argv' do
      allow(Process).to receive(:spawn).and_return(10, 11)
      supervisor.start_all
      expect(Process).to have_received(:spawn)
        .with(/walletd\z/, 'w1', 'mainnet', hash_including(:out, :err))
      expect(Process).to have_received(:spawn)
        .with(/walletd\z/, 'w2', 'mainnet', hash_including(:out, :err))
    end
  end

  describe '#stop_all' do
    before do
      allow(Process).to receive(:spawn).and_return(10, 11)
      supervisor.start_all
    end

    it 'returns :drained for processes that exit within the timeout' do
      allow(Process).to receive(:kill).with('TERM', anything)
      allow(Process).to receive(:waitpid2).and_return([10, instance_double(Process::Status)])
      result = supervisor.stop_all
      expect(result).to eq('w1' => :drained, 'w2' => :drained)
    end

    it 'sends SIGKILL and returns :killed for processes that exceed the timeout' do
      allow(Process).to receive(:kill)
      allow(Process).to receive(:waitpid2).and_return(nil)
      result = supervisor.stop_all
      expect(result).to eq('w1' => :killed, 'w2' => :killed)
      expect(Process).to have_received(:kill).with('KILL', 10)
      expect(Process).to have_received(:kill).with('KILL', 11)
    end

    it 'tolerates ESRCH from already-dead processes' do
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
      allow(Process).to receive(:waitpid2).and_return([10, instance_double(Process::Status)])
      expect { supervisor.stop_all }.not_to raise_error
    end
  end
end

# rubocop:enable RSpec/MultipleDescribes
