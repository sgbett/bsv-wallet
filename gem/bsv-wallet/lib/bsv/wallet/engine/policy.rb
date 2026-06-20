# frozen_string_literal: true

module BSV
  module Wallet
    class Engine
      # Limp-mode + headroom guard collaborator. Stateless: callers own
      # the +bypass:+ switch (Engine mutates +@bypass_limp_mode+ during
      # bootstrap windows where headroom guards are intentionally relaxed,
      # e.g. the import-utxo self-payment).
      #
      # Extracted from Engine's inline +enforce_*+ helpers in #402 Stage 2.
      # Threshold is fixed at construction time — Engine reads it from
      # +Engine.new(limp_threshold:)+ (which itself defaults to
      # +Engine::LIMP_THRESHOLD+ via the wallet's central config) and
      # constructs Policy with the resolved value.
      class Policy
        def initialize(threshold:)
          @threshold = threshold
        end

        # Raise +LimpModeError+ when +balance - spending+ would dip below
        # the configured threshold, unless +bypass:+ is true. The +spending+
        # default of 0 supports the limp-only check (balance vs threshold,
        # no projection) as a degenerate case of the projected-headroom
        # check — one method, two callers.
        #
        # The strict +<+ comparison matches +Engine#limp_mode?+: at the
        # threshold the wallet is not in limp mode.
        #
        # @raise [BSV::Wallet::LimpModeError]
        def guard_balance!(balance:, spending: 0, bypass: false)
          return if bypass

          projected = balance - spending
          return unless projected < @threshold

          raise BSV::Wallet::LimpModeError.new(balance: projected, threshold: @threshold)
        end
      end
    end
  end
end
