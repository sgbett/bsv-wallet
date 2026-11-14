# frozen_string_literal: true

require 'yaml'

module DocsGuard
  # Finds vocabulary that the glossary's "Retired terms" table retires,
  # and references to removed binaries, in prose and code comments.
  #
  # The term list, the paths scanned and the exemptions live in a YAML file
  # (+retired_terms.yml+) so a new retirement is a data change. A term with
  # +pending:+ is reported but doesn't fail: its removal belongs to the
  # issue named, and the entry goes live when that issue lands.
  class RetiredTerms
    Term = Data.define(:retired, :pattern, :use_instead, :row, :exempt, :pending)
    Finding = Data.define(:path, :line, :term, :text)
    Section = Data.define(:path, :heading)

    GLOSSARY = 'docs/reference/glossary.md'
    GLOSSARY_SECTION = 'Retired terms'

    # @param config_path [String] the YAML term list
    # @param root [String] repository root; every path in the config is relative to it
    def self.from_file(config_path, root:)
      config = YAML.safe_load_file(config_path)
      new(
        root: root,
        scan: config.fetch('scan'),
        skip: config.fetch('skip', []),
        exempt_sections: config.fetch('exempt_sections', []).map { |s| Section.new(s.fetch('path'), s.fetch('heading')) },
        terms: config.fetch('terms').map { |t| build_term(t) },
        manual_rows: config.fetch('manual', [])
      )
    end

    def self.build_term(entry)
      Term.new(
        retired: entry.fetch('retired'),
        pattern: Regexp.new(entry.fetch('pattern'), Regexp::IGNORECASE),
        use_instead: entry.fetch('use_instead'),
        row: entry['row'],
        exempt: entry.fetch('exempt', []),
        pending: entry['pending']
      )
    end

    # @param manual_rows [Array<String>] glossary rows no pattern can
    #   detect, left to review
    def initialize(root:, scan:, terms:, skip: [], exempt_sections: [], manual_rows: [])
      @root = File.expand_path(root)
      @scan = scan
      @skip = skip
      @terms = terms
      @exempt_sections = exempt_sections
      @manual_rows = manual_rows
    end

    # @return [Array<Finding>] every hit, pending terms included
    def findings
      @findings ||= files.flat_map { |path| findings_in(path) }
    end

    # @return [Array<Finding>] the hits that fail the check
    def violations
      findings.reject { |f| f.term.pending }
    end

    # Ways the term list itself has gone stale.
    #
    # @return [Array<String>]
    def problems
      unmapped_rows + finished_pending + missing_exempt_paths
    end

    private

    # Every row of the glossary's table is either detected by a term or
    # listed as manual, so a new retirement can't be added to the glossary
    # without a decision about enforcing it.
    def unmapped_rows
      covered = @terms.map(&:row).compact + @manual_rows
      glossary_rows.reject { |row| covered.include?(row) }.map do |row|
        "glossary row \"#{row}\" has no term (add one with row:) and isn't listed under manual:"
      end
    end

    def glossary_rows
      path = File.join(@root, GLOSSARY)
      return [] unless File.file?(path)

      lines = File.readlines(path)
      section = DocsGuard.headings(lines).find { |h| h.text == GLOSSARY_SECTION }
      return [] unless section

      lines.drop(section.index + 1).take_while { |l| !l.start_with?('#') }
           .select { |l| l.start_with?('|') }.drop(2)
           .map { |l| l.split('|')[1].strip }
    end

    def finished_pending
      hit = findings.map(&:term)
      @terms.select { |t| t.pending && !hit.include?(t) }.map do |t|
        "pending term \"#{t.retired}\" has no hits left; #{t.pending} has landed, so delete its pending: key"
      end
    end

    def missing_exempt_paths
      @terms.flat_map { |t| t.exempt.map { |p| [t, p] } }.reject { |_, p| File.exist?(File.join(@root, p)) }
            .map { |t, p| "\"#{t.retired}\" exempts #{p}, which doesn't exist" }
    end

    def files
      @scan.flat_map { |entry| expand(entry) }.reject { |path| skipped?(path) }.uniq.sort
    end

    def expand(entry)
      absolute = File.join(@root, entry)
      return [entry] if File.file?(absolute)

      Dir.glob('**/*', base: absolute).map { |p| File.join(entry, p) }.select { |p| File.file?(File.join(@root, p)) }
    end

    def skipped?(path)
      @skip.any? { |s| path == s || path.start_with?("#{s}/") }
    end

    def findings_in(path)
      content = File.binread(File.join(@root, path)).force_encoding(Encoding::UTF_8).scrub
      return [] if content.include?("\0")

      lines = content.lines
      exempt = exempt_lines(path, lines)
      lines.each_with_index.flat_map do |text, index|
        next [] if exempt.include?(index) || DocsGuard.dated_entry?(text)

        @terms.filter_map do |term|
          next if term.exempt.include?(path) || !term.pattern.match?(text)

          Finding.new(path: path, line: index + 1, term: term, text: text.strip)
        end
      end
    end

    # Line indexes inside an exempted section: from its heading to the
    # next heading at the same level or above.
    def exempt_lines(path, lines)
      sections = @exempt_sections.select { |s| s.path == path }
      return [] if sections.empty?

      headings = DocsGuard.headings(lines)
      sections.flat_map do |section|
        start = headings.find { |h| h.text == section.heading }
        next [] unless start

        stop = headings.find { |h| h.index > start.index && h.level <= start.level }
        (start.index...(stop&.index || lines.size)).to_a
      end
    end
  end
end
