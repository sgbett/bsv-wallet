# frozen_string_literal: true

require_relative 'base'

module BSV
  module Wallet
    module CLI
      module Commands
        # +bin/wallet reject <action_id>+ — abandon a pending action.
        #
        # Aligns with the project's no-invalid-state invariant: pending
        # actions are rejectable, broadcast-accepted actions are not.
        # Hard fail on non-rejectable state; the action stays in its
        # current valid state.
        #
        # +action_id+ is the wallet's INTEGER primary key (the +id:+
        # field from +bin/wallet list actions+), NOT the BRC-100 UUID
        # reference. The native CLI uses wallet vocab; the sibling
        # +bin/brc100+ surface uses references. Both stable identifiers
        # show up in +list actions+ output; operators pick the one that
        # matches their CLI.
        #
        # Engine error handling:
        # - +InvalidParameterError+ (unknown action_id, e.g. typo or stale
        #   id) is translated to +UsageError+ → exit 2, matching the CLI
        #   "bad argument" path. Same class as the up-front shape check.
        # - +CannotRejectInternalActionError+ (broadcast_intent == 'none')
        #   bubbles through +Wallet::Error+ → exit 1: the action exists
        #   but cannot be rejected — a genuine engine-state condition.
        # - +CannotRejectAcceptedActionError+ (broadcast accepted on-chain)
        #   same: bubbles → exit 1. Operator response is investigation,
        #   not retry.
        class Reject < Base
          def name = 'reject'

          def build_parser
            @options = {}
            OptionParser.new do |opts|
              opts.banner = 'Usage: bin/wallet reject <action_id>'
            end
          end

          def call(args)
            parser.parse!(args)
            action_id_str = args.shift
            if action_id_str.nil? || action_id_str.empty?
              raise UsageError,
                    'reject requires <action_id> (positive integer; ' \
                    'see id: from `bin/wallet list actions`)'
            end
            raise UsageError, "reject: unexpected extra arguments (got #{args.length})" unless args.empty?

            action_id = parse_action_id!(action_id_str)
            engine = @ctx[:engine]

            begin
              engine.reject_action(action_id: action_id)
            rescue BSV::Wallet::InvalidParameterError => e
              # Unknown action_id is operator input (typo, stale id) —
              # CLI semantics put it on the UsageError → exit 2 path
              # alongside other "bad argument" errors. The other two
              # rejection failures (CannotRejectInternalActionError,
              # CannotRejectAcceptedActionError) are genuine engine-state
              # conditions where the action exists but can't be rejected;
              # those bubble through Wallet::Error → exit 1.
              raise UsageError, e.message
            end

            emit_human "rejected: action #{action_id}"
            0
          end

          private

          # Parse the positional <action_id> as a positive integer. CLI-side
          # shape check fails fast for typos rather than round-tripping
          # through the engine's DB lookup (which still raises
          # InvalidParameterError for unknown-but-well-formed ids).
          def parse_action_id!(arg)
            id = Integer(arg, 10)
            raise UsageError, "reject <action_id> must be a positive integer (got #{id})" if id <= 0

            id
          rescue ArgumentError
            raise UsageError, "reject <action_id> must be a positive integer (got #{safe_preview(arg)})"
          end
        end
      end
    end
  end
end
