# frozen_string_literal: true

module BSV
  module Wallet
    module CLI
      # Exit-code-carrying error hierarchy for the +bin/wallet+ dispatcher.
      #
      # Commands +raise+; the dispatcher +rescue+s at the top and translates
      # to the appropriate process exit code via +#exit_code+. No +abort+
      # inside commands — that bypasses the contract and is hard to test.
      #
      # Code scheme (loosely matching shell conventions):
      #   1 — generic runtime failure (engine raised, network down, etc.)
      #   2 — usage error (bad flag, missing required arg, unknown command)
      #   3 — domain error specific to the action requested
      #         (e.g. +reject+ on an already-broadcast action)
      class Error < StandardError
        def exit_code = 1
      end

      # Bad flags, unknown command, missing required arguments. Anything
      # the user could have avoided by reading +--help+.
      class UsageError < Error
        def exit_code = 2
      end

      # The engine raised a +BSV::Wallet::Error+ (or descendant). Wrapped
      # so the dispatcher can translate to the standard exit code without
      # leaking engine internals into its rescue clauses.
      class EngineError < Error
        def exit_code = 1
      end

      # The user tried to +reject+ an action that isn't in a rejectable
      # state — only pending actions are rejectable. Distinct exit code so
      # shell pipelines can branch on this specific outcome without parsing
      # error text. Aligns with the no-invalid-state invariant: the action
      # stays in its current valid state; failure is observable, not
      # destructive.
      class NotRejectableError < Error
        def exit_code = 3
      end

      # +--wif=<wif>+ supplied on argv with stdin attached to a TTY and
      # +--allow-insecure-wif+ unset. Refusal is policy: the WIF would
      # otherwise land in +~/.bash_history+, +ps auxww+, container logs,
      # and process accounting. See +Secrets on the CLI+ in the plan.
      class InsecureWifError < UsageError
        def exit_code = 2
      end
    end
  end
end
