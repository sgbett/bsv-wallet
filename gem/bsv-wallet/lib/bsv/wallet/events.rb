# frozen_string_literal: true

require 'time'

module BSV
  module Wallet
    # Structured event emission for wallet daemon observability.
    #
    # Writes a single line — same content — to up to two sinks:
    #
    # 1. +BSV.logger+ (SDK-level, default debug-mode logger). The line
    #    goes through whatever formatter that logger has, mixed in with
    #    +[Store]+ / +[Engine]+ / +[Protocol]+ debug spam. Suitable for
    #    interactive development.
    #
    # 2. +BSV::Wallet.event_log+ (opt-in, wallet-scoped). Canonical
    #    +<ISO-8601> [event] name key=value …+ format with no Logger
    #    prefix junk; suitable for +tail -f+ / +grep+ over a sustained
    #    run (per the #126 e2e harness's observability contract).
    #
    # Line format:
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

    # Canonical formatter for the event_log sink. Produces lines that
    # tail/grep cleanly without the standard Logger date/severity/PID
    # prefix.
    EVENT_LOG_FORMATTER = lambda do |_severity, datetime, _progname, msg|
      "#{datetime.utc.iso8601(3)} #{msg}\n"
    end

    class << self
      # Opt-in per-event log sink. When set, emit writes the canonical
      # +[event] name key=value …+ line here AND to +BSV.logger+ (if set).
      # The setter auto-applies {EVENT_LOG_FORMATTER} so the sink's lines
      # are always tail/grep-friendly regardless of the caller's
      # +Logger.new+ defaults.
      #
      # @example wire a per-run logfile from a harness
      #   require 'logger'
      #   BSV::Wallet.event_log = Logger.new('tmp/e2e.log')
      attr_reader :event_log

      def event_log=(logger)
        logger.formatter = EVENT_LOG_FORMATTER if logger
        @event_log = logger
      end
    end

    def self.emit(name, **payload)
      return if BSV.logger.nil? && @event_log.nil?

      fields = payload.map { |k, v| format_field(k, v) }.compact.join(' ')
      message = "[event] #{name}"
      message = "#{message} #{fields}" unless fields.empty?

      BSV.logger&.info(message)
      @event_log&.info(message)
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
