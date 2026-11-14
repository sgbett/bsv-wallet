# frozen_string_literal: true

require 'spec_helper'
require 'bsv-wallet'
require 'fileutils'
require 'tmpdir'

RSpec.describe BSV::Wallet::Engine::HintsEndpoint do
  describe '.validate!' do
    it 'accepts an ipc:// filesystem path' do
      expect(described_class.validate!('ipc:///home/wallet/.bsv-wallet/hints.sock'))
        .to eq('ipc:///home/wallet/.bsv-wallet/hints.sock')
    end

    it 'accepts an inproc:// endpoint, which never leaves the process' do
      expect(described_class.validate!('inproc://hints')).to eq('inproc://hints')
    end

    {
      'tcp://127.0.0.1:5555' => %r{tcp://},
      'tcp://*:5555' => %r{tcp://},
      'udp://127.0.0.1:5555' => %r{udp://},
      'ipc://@bsv-wallet-hints' => /abstract/,
      '/home/wallet/.bsv-wallet/hints.sock' => %r{ipc://},
      'ipc://' => /path/
    }.each do |endpoint, message|
      it "refuses #{endpoint.inspect}" do
        expect { described_class.validate!(endpoint) }
          .to raise_error(BSV::Wallet::ConfigurationError, message)
      end
    end
  end

  describe '.bind' do
    let(:dir) { Dir.mktmpdir('hints') }
    let(:path) { File.join(dir, 'hints.sock') }
    let(:endpoint) { "ipc://#{path}" }
    let(:socket) { double('OMQ::PULL', bind: nil) }

    after { FileUtils.rm_rf(dir) }

    it 'creates the socket file owner-only, whatever the umask, and restores the umask' do
      saved = File.umask(0o000)
      mode = umask_after = nil
      Async do
        pull = OMQ::PULL.new
        described_class.bind(pull, endpoint)
        mode = File.stat(path).mode & 0o777
        umask_after = File.umask
      ensure
        pull&.close
      end

      expect(mode).to eq(0o600)
      expect(umask_after).to eq(0o000)
    ensure
      File.umask(saved)
    end

    it 'restores the umask when the bind raises' do
      allow(socket).to receive(:bind).and_raise(Errno::EADDRINUSE)
      saved = File.umask

      expect { described_class.bind(socket, endpoint) }.to raise_error(Errno::EADDRINUSE)
      expect(File.umask).to eq(saved)
    end

    it 'refuses a world-writable directory' do
      File.chmod(0o777, dir)

      expect { described_class.bind(socket, endpoint) }
        .to raise_error(BSV::Wallet::ConfigurationError, /writable/)
      expect(socket).not_to have_received(:bind)
    end

    it 'refuses a group-writable directory' do
      File.chmod(0o770, dir)

      expect { described_class.bind(socket, endpoint) }
        .to raise_error(BSV::Wallet::ConfigurationError, /writable/)
      expect(socket).not_to have_received(:bind)
    end

    it 'refuses a directory owned by another user' do
      other = instance_double(File::Stat, directory?: true, owned?: false, mode: 0o40700)
      allow(File).to receive(:stat).and_call_original
      allow(File).to receive(:stat).with(dir).and_return(other)

      expect { described_class.bind(socket, endpoint) }
        .to raise_error(BSV::Wallet::ConfigurationError, /owned by another user/)
      expect(socket).not_to have_received(:bind)
    end

    it 'refuses a directory that does not exist' do
      missing = "ipc://#{File.join(dir, 'missing', 'hints.sock')}"

      expect { described_class.bind(socket, missing) }
        .to raise_error(BSV::Wallet::ConfigurationError, /does not exist/)
    end

    it 'refuses a tcp:// endpoint before binding' do
      expect { described_class.bind(socket, 'tcp://127.0.0.1:0') }
        .to raise_error(BSV::Wallet::ConfigurationError, %r{tcp://})
      expect(socket).not_to have_received(:bind)
    end

    it 'binds an inproc:// endpoint without a filesystem check' do
      described_class.bind(socket, 'inproc://hints')

      expect(socket).to have_received(:bind).with('inproc://hints')
    end
  end
end
