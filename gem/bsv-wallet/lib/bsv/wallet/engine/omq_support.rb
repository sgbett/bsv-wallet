# frozen_string_literal: true

module BSV
  module Wallet
    class Engine
      # Shared OMQ socket helpers for Engine logical models.
      #
      # Provides bind_or_die — wraps an OMQ bind call, emitting a
      # structured fiber.crashed event and re-raising on failure.
      # Without this, a bind error (e.g. inproc endpoint already bound
      # by another process or test) would silently leave the engine
      # deaf with no operator signal. Per #176.
      module OmqSupport
        private

        def bind_or_die(task_name)
          yield
        rescue StandardError => e
          BSV::Wallet.emit('fiber.crashed', task: task_name, error: e.message.lines.first&.chomp)
          raise
        end
      end
    end
  end
end
