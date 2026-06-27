# frozen_string_literal: true

module BSV
  module Wallet
    module CLI
      # Value object carrying global flags parsed by the dispatcher and
      # passed to each command. Immutable (+Data.define+) so a command
      # can't accidentally mutate state observable by a sibling.
      #
      # Constructed by +Dispatcher.parse_global_options+ after the global
      # flag pass; consumed by command classes via their +ctx+ argument
      # and by +CLI.boot+ for wallet/db resolution.
      #
      # Fields:
      #   - +wallet_name+      — value of +--wallet=<name>+; +nil+ if unset
      #   - +network+          — +:mainnet+ / +:testnet+ / +nil+
      #   - +json+             — +true+ if +--json+ forces JSON on TTY
      #   - +wif_override+     — value of +--wif=<wif>+ (after policy check)
      #                          or +--wif-file=<path>+ contents; +nil+ if unset
      #   - +database_url_override+ — value of +--database-url=<url>+ (after
      #                          userinfo-password check); +nil+ if unset
      #   - +env_file+         — value of +--env=<file>+; +nil+ if unset
      GlobalOptions = Data.define(
        :wallet_name,
        :network,
        :json,
        :wif_override,
        :database_url_override,
        :env_file
      ) do
        # Convenience constructor with sensible defaults; lets callers
        # (and specs) build an empty options object without spelling out
        # every field.
        def self.default
          new(
            wallet_name: nil,
            network: nil,
            json: false,
            wif_override: nil,
            database_url_override: nil,
            env_file: nil
          )
        end
      end
    end
  end
end
