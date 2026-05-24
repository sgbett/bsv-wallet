# frozen_string_literal: true

module BSV
  module Wallet
    # Structured event emission for wallet daemon observability.
    #
    # Writes a single line to BSV.logger at :info level. Format:
    #
    #   [event] <name> key=value key=value ...
    #
    # Convention: values should be "shell word" shaped (no spaces). The
    # helper quotes values containing whitespace as a safety net, but
    # callers should normalize (e.g. reason=arc_rejected, not
    # reason="ARC rejected the tx"). No secrets, no binary blobs, and
    # no spaces in values.
    #
    # Canonical event names — keep in sync with this comment as the
    # taxonomy evolves:
    #
    #   daemon.started       wallet=X network=Y
    #   daemon.stopped       reason=signal
    #   fiber.crashed        task=X error=...
    #   task.discovered      task=X count=N
    #   task.enqueued        task=X id=N
    #   task.dispatched      task=X id=N
    #   task.succeeded       task=X id=N latency_ms=M outcome=...
    #   task.failed          task=X id=N latency_ms=M reason=...
    #   task.aborted         task=X id=N reason=... arc_status=...
    #   task.skipped         task=X id=N reason=...
    #
    def self.emit(name, **payload)
      return unless BSV.logger

      fields = payload.map { |k, v| format_field(k, v) }.compact.join(' ')
      message = "[event] #{name}"
      message = "#{message} #{fields}" unless fields.empty?
      BSV.logger.info(message)
    end

    # Format a single key=value pair for structured log output.
    #
    # Returns nil for nil values (caller uses .compact to skip them).
    # Quotes values containing whitespace; escapes embedded double quotes.
    def self.format_field(key, value)
      return nil if value.nil?

      str = value.to_s
      str = "\"#{str.gsub('"', '\\"')}\"" if str.match?(/\s/)
      "#{key}=#{str}"
    end
  end
end
