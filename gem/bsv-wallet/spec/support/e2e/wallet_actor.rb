# frozen_string_literal: true

require 'open3'
require 'json'
require 'sequel'

module E2E
  # Per-wallet test stand-in driven via `bin/` subprocess calls.
  #
  # Each WalletActor wraps one named wallet (sdk, w1, ...) and exposes
  # the operations a person would perform via the CLI: create a payment,
  # internalize a received envelope, read the balance, reset state.
  # Each method shells out to the corresponding `bin/` tool; the actor
  # itself holds no live DB connection, so multiple actors coexist with
  # no Sequel-global cross-talk (each subprocess gets its own boot).
  #
  # This is the seed shape for #442. When #431 lands a `bin/brc100` CLI
  # the actor grows a `brc100:` routing flag; when #433 lands the native
  # porcelain the actor's `sh` invocations swap to the new tool names.
  # The public surface (`create`, `internalize`, `available_funds`,
  # `identity_key`) stays the same.
  class WalletActor
    attr_reader :name

    # Test-time setup. Populates Fixtures (derived WIFs from
    # BSV_WALLET_WIF_SDK) and exports each WIF to ENV so spawned
    # subprocesses — which boot a fresh in-process Fixtures registry —
    # can resolve named wallets from ENV.
    def self.install!
      E2E::WalletHarness.install_fixtures!
      BSV::Wallet::Fixtures.registry.each do |fixture|
        next unless fixture.wif

        ENV["BSV_WALLET_WIF_#{fixture.name.to_s.upcase}"] = fixture.wif
      end
    end

    def initialize(name)
      @name = name.to_s
    end

    # Identity pubkey hex. Derived from the wallet's WIF (held in the
    # Fixtures registry); pure crypto, no DB. Placeholder until
    # `bin/brc100 getPublicKey identityKey:true` lands under #431.
    def identity_key
      @identity_key ||= begin
        wif = BSV::Wallet::Fixtures.wallet(@name.to_sym).wif
        BSV::Primitives::PrivateKey.from_wif(wif).public_key.to_hex
      end
    end

    # Build + sign a no_send payment to recipient. Returns the parsed
    # envelope hash: { 'beef', 'dtxid', 'sender_identity_key', 'outputs' }.
    def create(recipient_identity_key, sats)
      JSON.parse(sh('create', recipient_identity_key, sats.to_s, '--no-send'))
    end

    # Internalize a received envelope as a wallet payment (lands in the
    # unbasketed pool, the same place change lands — per the
    # core-vs-conformance reference).
    def internalize(envelope, description: 'transmit')
      args = ['--description', description]
      envelope['outputs'].each do |out|
        spec = [
          out['vout'],
          'wallet',
          out['derivation_prefix'],
          out['derivation_suffix'],
          envelope['sender_identity_key']
        ].join(':')
        args.push('--output', spec)
      end
      beef_binary = [envelope.fetch('beef')].pack('H*')
      sh('internalize', *args, stdin: beef_binary)
    end

    # Total satoshis across all spendable outputs (no basket filter,
    # so basketed + unbasketed both counted).
    def available_funds
      sh('balance').strip.to_i
    end

    # Pull on-chain root-P2PKH UTXOs into the wallet DB via no_send
    # self-payment. Idempotent — re-importing existing UTXOs is a no-op.
    def import!
      sh('import', '--no-send')
    end

    # Truncate the actions table (with CASCADE) so all per-action state
    # — outputs, spendable, output_baskets, broadcasts, transmissions,
    # promotions — is wiped. Append-only chain knowledge (`tx_proofs`,
    # `blocks`) and basket-name registrations are preserved (internalize
    # is idempotent on duplicate proofs). Uses a direct Sequel connection
    # (no Engine boot, no Sequel::Model rebinding) so resets don't
    # pollute the global model bindings the next subprocess sets up.
    def reset!
      url = BSV::Wallet::Fixtures.wallet(@name.to_sym).database_url
      Sequel.connect(url) do |db|
        db.run('TRUNCATE TABLE actions CASCADE')
      end
    end

    private

    def sh(cmd, *args, stdin: nil)
      bin = File.expand_path("../../../bin/#{cmd}", __dir__)
      out, err, status = Open3.capture3(bin, @name, *args, stdin_data: stdin)
      unless status.success?
        raise "bin/#{cmd} #{@name} #{args.join(' ')} failed " \
              "(exit #{status.exitstatus}):\n#{err}"
      end
      out
    end
  end
end
