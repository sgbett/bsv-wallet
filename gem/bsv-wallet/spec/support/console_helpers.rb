# frozen_string_literal: true

# Shared helper for specs that exercise OMQ bind-failure paths.
#
# Async logs child-task failures via Console.logger by default, which
# dumps a stack trace to stderr. When we're asserting the visibility
# via the structured fiber.crashed event, that noise is unhelpful.
# This helper silences Console for the duration of a block.
module ConsoleHelpers
  def suppress_console_errors
    original = Console.logger.level
    Console.logger.level = Logger::FATAL
    yield
  ensure
    Console.logger.level = original
  end
end
