# frozen_string_literal: true

require 'spec_helper'
require 'bsv/wallet/cli/commands/send'

RSpec.describe BSV::Wallet::CLI::Commands::Send do
  let(:engine) { instance_double(BSV::Wallet::Engine) }
  let(:key_deriver) { instance_double(BSV::Wallet::KeyDeriver) }
  let(:identity_key) { "02#{'a' * 64}" }
  let(:ctx) do
    { engine: engine, key_deriver: key_deriver, identity_key: identity_key }
  end
  let(:global_options) { BSV::Wallet::CLI::GlobalOptions.default }
  let(:command) { described_class.new(ctx: ctx, global_options: global_options) }

  # Deterministic wtxid for stubbed engine returns. Wire-order binary;
  # CLI flips to display order when printing.
  let(:fake_wtxid) { ('a'..'p').to_a.map(&:ord).pack('C*').slice(0, 32) || ("\x00" * 32) }
  let(:fake_atomic_beef) { "\x01\x02\x03BEEF".b }

  describe 'recipient detection' do
    it 'rejects missing recipient' do
      expect { command.call([]) }.to raise_error(BSV::Wallet::CLI::UsageError, /requires <recipient> <sats>/)
    end

    it 'rejects missing sats' do
      expect { command.call(['1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa']) }.to raise_error(BSV::Wallet::CLI::UsageError, /requires <recipient> <sats>/)
    end

    it 'rejects non-integer sats' do
      expect do
        command.call(%w[1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa abc])
      end.to raise_error(BSV::Wallet::CLI::UsageError, /sats must be an integer/)
    end

    it 'rejects zero sats' do
      expect do
        command.call(%w[1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa 0])
      end.to raise_error(BSV::Wallet::CLI::UsageError, /sats must be > 0/)
    end

    it 'rejects negative sats (via OptionParser intercept on leading dash)' do
      # OptionParser sees the leading '-' and treats '-100' as an unknown
      # flag — that's the dispatcher's natural rescue path (translated to
      # exit code 2 in real CLI use). Pure-negative integers as
      # positionals are an operator-error case; the dispatcher catches
      # them, not us.
      expect do
        command.call(['1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa', '-100'])
      end.to raise_error(OptionParser::InvalidOption)
    end

    it 'rejects unrecognised recipient shape' do
      expect do
        command.call(%w[neither-address-nor-key 100])
      end.to raise_error(BSV::Wallet::CLI::UsageError, /not recognised/)
    end

    # If an operator mistypes a WIF (or anything else long) into the
    # recipient slot, the unknown-recipient error must NOT echo the
    # full value to stderr — that would persist secret material into
    # shell history, CI logs, bug reports. Short values still pass
    # through verbatim (too short to be a WIF).
    it 'truncates long unknown recipients in the error message (defence against WIF echoing)' do
      wif_lookalike = "L#{'a' * 51}" # 52 chars, WIF-shape
      expect { command.call([wif_lookalike, '100']) }
        .to raise_error(BSV::Wallet::CLI::UsageError) do |error|
          expect(error.message).not_to include(wif_lookalike)
          expect(error.message).to include('52 chars')
        end
    end

    it 'shows short unknown recipients verbatim (diagnostic for typos)' do
      expect { command.call(%w[oops 100]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /"oops"/)
    end

    # P2SH mainnet addresses lead with '3'; P2SH testnet with '2'. Both
    # are valid Base58Check but would produce an unspendable P2PKH lock
    # if the embedded 20-byte hash got wrapped in OP_DUP/OP_HASH160/.../
    # OP_CHECKSIG. Two lines of defence: regex prefix exclusion +
    # post-decode version-byte validation. We test the regex line here
    # (cheap, no decode).
    it 'rejects mainnet P2SH addresses (leading 3)' do
      expect do
        command.call(%w[3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy 1000])
      end.to raise_error(BSV::Wallet::CLI::UsageError, /not recognised/)
    end

    it 'rejects testnet P2SH addresses (leading 2)' do
      expect do
        command.call(%w[2N2JD6wb56AfK4tfmM6PwdVmoYk2dCKf4Br 1000])
      end.to raise_error(BSV::Wallet::CLI::UsageError, /not recognised/)
    end

    it 'raises UsageError on Base58Check checksum failure (no engine call)' do
      allow(engine).to receive(:build_action)
      # Mainnet P2PKH-prefixed address with a corrupted checksum byte.
      expect do
        command.call(%w[1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNX 1000])
      end.to raise_error(BSV::Wallet::CLI::UsageError)
      expect(engine).not_to have_received(:build_action)
    end

    it 'raises UsageError on non-standard Base58Check payload length (no engine call)' do
      # Stub the SDK to simulate a checksum-valid but non-standard
      # payload (e.g. 10 bytes instead of 21). Real-world this is rare,
      # but without the length check an empty payload would TypeError
      # on +format('%02x', nil)+ and an oversized payload would build a
      # malformed P2PKH lock with the wrong hash length — misdirecting
      # funds.
      allow(BSV::Primitives::Base58).to receive(:check_decode).and_return("\x00".b * 10)
      allow(engine).to receive(:build_action)
      expect do
        command.call(%w[1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa 1000])
      end.to raise_error(BSV::Wallet::CLI::UsageError, /10-byte payload/)
      expect(engine).not_to have_received(:build_action)
    end
  end

  describe 'base58 path' do
    let(:base58_address) { '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa' }

    before do
      # Real Base58Check decode; no stub needed. The address above is
      # the well-known Satoshi address.
      allow(engine).to receive(:build_action).and_return(
        wtxid: fake_wtxid, atomic_beef: fake_atomic_beef
      )
    end

    it 'calls engine.build_action with a P2PKH output, no derivation hints, randomize_outputs: false' do
      command.call([base58_address, '1000'])

      expect(engine).to have_received(:build_action).with(
        description: 'cli-send',
        outputs: array_including(
          hash_including(
            satoshis: 1000,
            locking_script: instance_of(String),
            output_description: 'payment'
          )
        ),
        accept_delayed_broadcast: false,
        no_send: false,
        randomize_outputs: false
      )
    end

    it 'does NOT emit a JSON envelope (base58 recipient is presumed to control the key)' do
      expect { command.call([base58_address, '1000']) }.not_to output(/\{/).to_stdout
    end

    it 'maps --broadcast=async to accept_delayed_broadcast: true' do
      command.call([base58_address, '1000', '--broadcast=async'])
      expect(engine).to have_received(:build_action).with(
        hash_including(accept_delayed_broadcast: true)
      )
    end

    it 'maps --broadcast=none to no_send: true' do
      command.call([base58_address, '1000', '--broadcast=none'])
      expect(engine).to have_received(:build_action).with(
        hash_including(no_send: true, accept_delayed_broadcast: false)
      )
    end

    it 'forwards --description' do
      command.call([base58_address, '1000', '--description=invoice-77'])
      expect(engine).to have_received(:build_action).with(
        hash_including(description: 'invoice-77')
      )
    end

    it 'prints human-readable summary to stderr' do
      expect { command.call([base58_address, '1000']) }.to output(/kind:\s+base58/).to_stderr
    end
  end

  describe 'identity-key path' do
    let(:derived_pubkey) { "\u0002#{"\x42" * 32}".b }

    before do
      allow(BSV::Wallet).to receive(:random_derivation).and_return('deadbeef0000')
      allow(key_deriver).to receive(:derive_public_key).and_return(derived_pubkey)
      allow(engine).to receive(:build_action).and_return(
        wtxid: fake_wtxid, atomic_beef: fake_atomic_beef
      )
    end

    it 'derives a recipient pubkey via BRC-42 with BRC-29 protocol level' do
      command.call([identity_key, '5000'])
      expect(key_deriver).to have_received(:derive_public_key).with(
        protocol_id: [2, 'deadbeef0000'],
        key_id: '1',
        counterparty: identity_key,
        for_self: true
      )
    end

    it 'calls engine.build_action with derivation hints in the output spec' do
      command.call([identity_key, '5000'])
      expect(engine).to have_received(:build_action).with(
        hash_including(
          outputs: array_including(
            hash_including(
              satoshis: 5000,
              derivation_prefix: 'deadbeef0000',
              derivation_suffix: '1',
              sender_identity_key: identity_key
            )
          )
        )
      )
    end

    it 'emits a JSON envelope on stdout with beef hex + per-output hints' do
      expect { command.call([identity_key, '5000']) }.to output(/"beef":/).to_stdout
    end

    it 'envelope carries the derivation prefix/suffix for recipient recovery' do
      expect { command.call([identity_key, '5000']) }.to output(/"derivation_prefix":"deadbeef0000"/).to_stdout
    end

    it 'envelope carries the sender_identity_key' do
      expect { command.call([identity_key, '5000']) }.to output(/"sender_identity_key":"#{identity_key}"/).to_stdout
    end

    it 'envelope carries the dtxid' do
      expected_dtxid = fake_wtxid.reverse.unpack1('H*')
      expect { command.call([identity_key, '5000']) }.to output(/"dtxid":"#{expected_dtxid}"/).to_stdout
    end

    it 'maps --broadcast=none to no_send: true on the identity-key path' do
      command.call([identity_key, '5000', '--broadcast=none'])
      expect(engine).to have_received(:build_action).with(
        hash_including(no_send: true, accept_delayed_broadcast: false)
      )
    end

    it 'still emits the envelope when --broadcast=none' do
      expect { command.call([identity_key, '5000', '--broadcast=none']) }.to output(/"beef":/).to_stdout
    end
  end
end
