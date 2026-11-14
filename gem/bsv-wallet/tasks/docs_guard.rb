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
  FENCE = /\A\s*(?<marker>`{3,}|~{3,})(?<info>.*)/
  HEADING = /\A(#+)\s+(.+?)\s*\z/

  # A fenced code block, from its opening line. +info+ is the language,
  # empty for a fence with none.
  Fence = Data.define(:marker, :info) do
    # CommonMark: only a bare run of the opener's character, at least as
    # long, closes the fence, so a +```+ line inside a +~~~+ fence is
    # content.
    def closed_by?(line)
      match = FENCE.match(line)
      return false unless match && match[:info].strip.empty?

      match[:marker][0] == marker[0] && match[:marker].size >= marker.size
    end
  end

  module_function

  def dated_entry?(line)
    DATED_ENTRY.match?(line)
  end

  # Yields each line with its index, the Fence it belongs to (nil outside
  # one), and +:open+ or +:close+ on that fence's marker lines.
  def each_line_with_fence(lines)
    return enum_for(:each_line_with_fence, lines) unless block_given?

    fence = nil
    lines.each_with_index do |line, index|
      if fence
        edge = fence.closed_by?(line) ? :close : nil
        yield line, index, fence, edge
        fence = nil if edge
      elsif (match = FENCE.match(line))
        fence = Fence.new(marker: match[:marker], info: match[:info].strip)
        yield line, index, fence, :open
      else
        yield line, index, nil, nil
      end
    end
  end

  # Yields each line outside fenced code blocks, with its index.
  def each_unfenced_line(lines)
    return enum_for(:each_unfenced_line, lines) unless block_given?

    each_line_with_fence(lines) { |line, index, fence| yield line, index unless fence }
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
