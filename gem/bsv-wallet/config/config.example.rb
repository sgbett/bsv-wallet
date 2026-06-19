# frozen_string_literal: true

# ~/.bsv-wallet/config.rb — BSV Wallet end-user configuration template
#
# Copy to +~/.bsv-wallet/config.rb+ (or set +BSV_WALLET_CONFIG=<path>+).
# Loaded at boot by +BSV::Wallet.load_config_file!+; absent file is a
# clean no-op.
#
# Every setting below defaults from the corresponding shell ENV var
# inside +BSV::Wallet::Config#initialize+, so this file is OPTIONAL —
# the wallet works out of the box from your existing shell env. Use
# this file when you want to:
#
#   * pin a value explicitly (ignoring the ENV var entirely), or
#   * compute a value from something other than the default ENV var.
#
# Uncomment lines you want to override. The commented values shown
# are the built-in defaults +Config#initialize+ uses when the ENV var
# is unset.

BSV::Wallet.configure do |c|
  # --- Wallet identity ---

  # Database URL — single-wallet end-user mode. Sequel-compatible URL
  # (sqlite://, postgres://, etc.). Default reads +DATABASE_URL+.
  # c.database_url = 'postgres://localhost/my_wallet'

  # Wallet private key (WIF format). Default reads +WIF+.
  # c.wif = 'L1...'

  # Network: +:mainnet+ or +:testnet+. Default reads +BSV_WALLET_NETWORK+
  # (defaults to +:mainnet+ if unset).
  # c.network = :mainnet

  # --- Wallet behaviour ---

  # Limp mode threshold (sats). Below this, outbound operations are
  # blocked. Default 50_000; reads +LIMP_THRESHOLD+.
  # c.limp_threshold = 50_000

  # --- Daemon (walletd) ---

  # Sequel connection pool size for walletd. Default 16; reads
  # +BSV_WALLET_DAEMON_SEQUEL_CONNECTIONS+.
  # c.daemon_pool_size = 16

  # --- EF hint cache (#269) ---

  # Shared hydration cache capacity (entries) — the wtxid-keyed substrate
  # the broadcast EF path and the Hydrator's deep BEEF walk both read.
  # Default 20000 (sized for multi-hop cascade working sets); reads
  # +BSV_WALLET_TX_CACHE_SIZE+.
  # c.tx_cache_size = 20000

  # Optional cross-process EF hint socket. When set, producers (CLI,
  # API) PUSH hints to walletd via this socket, eliminating the
  # broadcast-time DB JOIN. Pick a path writable by all producer
  # processes and readable by walletd. Default +nil+ (feature off);
  # reads +BSV_WALLET_HINTS_SOCKET+.
  # c.hints_socket = '/tmp/bsv-wallet-hints.sock'
end
