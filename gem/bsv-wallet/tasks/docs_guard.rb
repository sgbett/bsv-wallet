# frozen_string_literal: true

# Guards that keep the documentation from drifting back to vocabulary and
# code the wallet no longer has (#545). Dev tooling: loaded by
# +docs_guard.rake+, never by +require 'bsv-wallet'+.
module DocsGuard
  Heading = Data.define(:index, :level, :text)

  # A change-log entry that opens with its date (+- *2026-06-25* — …+)
  # records what was true then, so neither guard holds it to today's code
  # or vocabulary.
  DATED_ENTRY = /\A\s*[-*]\s+[*_]{1,2}\d{4}-\d{2}-\d{2}[*_]{1,2}/
  FENCE = /\A\s*(```|~~~)/
  HEADING = /\A(#+)\s+(.+?)\s*\z/

  module_function

  def dated_entry?(line)
    DATED_ENTRY.match?(line)
  end

  # Yields each line outside fenced code blocks, with its index.
  def each_unfenced_line(lines)
    return enum_for(:each_unfenced_line, lines) unless block_given?

    fenced = false
    lines.each_with_index do |line, index|
      if FENCE.match?(line)
        fenced = !fenced
        next
      end
      yield line, index unless fenced
    end
  end

  # Markdown headings, ignoring +#+ comment lines inside fenced code.
  def headings(lines)
    each_unfenced_line(lines).filter_map do |line, index|
      match = HEADING.match(line)
      Heading.new(index: index, level: match[1].size, text: match[2]) if match
    end
  end
end

require_relative 'docs_guard/retired_terms'
require_relative 'docs_guard/code_index'
require_relative 'docs_guard/doc_references'
