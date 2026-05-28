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

    # In-process observer registry. Each observer is a callable that
    # receives +(name, payload)+ for every emit call. Used by
    # {Scheduler#shutdown} to drive a drain-tracking counter without
    # coupling to +Engine::Broadcast+ / +Engine::TxProof+ internals.
    #
    # Observers run synchronously on the emitting fiber; keep them
    # non-blocking and exception-safe. Exceptions from observers are
    # caught and logged at +:warn+ — a faulty observer must not break
    # event emission.
    @event_observers = []
    @event_observers_mutex = Mutex.new

    # Register an observer for every subsequent +emit+ call.
    #
    # @yieldparam name [String] event name (e.g. +'task.dispatched'+)
    # @yieldparam payload [Hash] the keyword payload passed to +emit+
    # @return [Proc] the registered observer (use as +handle+ for {.off_event})
    def self.on_event(&block)
      raise ArgumentError, 'block required' unless block

      @event_observers_mutex.synchronize { @event_observers << block }
      block
    end

    # Deregister a previously-registered observer.
    #
    # @param handle [Proc] the proc returned by {.on_event}
    # @return [Proc, nil] the removed observer, or nil if not found
    def self.off_event(handle)
      @event_observers_mutex.synchronize { @event_observers.delete(handle) }
    end

    # Snapshot of registered observers (testing).
    def self.event_observer_count
      @event_observers_mutex.synchronize { @event_observers.length }
    end

    # Clear the process-wide observer registry. Test helper — do not
    # call from production code. Specs that boot a Scheduler / Daemon
    # without a matching shutdown leak observers across examples; the
    # spec_helper hook uses this to keep examples isolated.
    def self.reset_event_observers!
      @event_observers_mutex.synchronize { @event_observers.clear }
    end

    def self.emit(name, **payload)
      observers = @event_observers_mutex.synchronize { @event_observers.dup }
      return if BSV.logger.nil? && @event_log.nil? && observers.empty?

      fields = payload.map { |k, v| format_field(k, v) }.compact.join(' ')
      message = "[event] #{name}"
      message = "#{message} #{fields}" unless fields.empty?

      BSV.logger&.info(message)
      @event_log&.info(message)
      observers.each do |observer|
        observer.call(name, payload)
      rescue StandardError => e
        BSV.logger&.warn { "[BSV::Wallet.emit] observer raised: #{e.message}" }
      end
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
