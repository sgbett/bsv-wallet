# frozen_string_literal: true

module BSV
  module Wallet
    class Engine
      # Single point of truth for wiring source-output data onto a
      # TransactionInput. Used by Engine::TxBuilder#build_inputs (inline
      # construction path, before signing) and
      # Engine::Broadcast#hydrated_transaction_for (daemon path, after
      # parsing raw_tx). Both paths converge here so the SDK can
      # serialize the transaction to Extended Format on the wire.
      module InputSource
        module_function

        # Attach source-output data to a TransactionInput.
        #
        # +source+ is a row from +Store#resolve_inputs_for_signing+ carrying
        # +:source_satoshis+ (Integer) and +:source_locking_script+ (binary
        # bytes). The locking script is wrapped in +BSV::Script::Script+
        # for the SDK's EF serializer.
        #
        # @param input  [Transaction::TransactionInput]
        # @param source [Hash] row from Store#resolve_inputs_for_signing
        def attach!(input, source)
          input.source_satoshis = source[:source_satoshis]
          input.source_locking_script = BSV::Script::Script.from_binary(source[:source_locking_script])
        end
      end
    end
  end
end
