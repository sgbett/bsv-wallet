# frozen_string_literal: true

require 'yaml'

module DocsGuard
  # Finds references in Markdown to things that don't exist: classes,
  # modules and methods written in inline code (+Engine::Hydrator+,
  # +Store#find_proof+), +bin/+ executables, file paths, and migration
  # numbers.
  #
  # Class and method names resolve through a CodeIndex. A reference a doc
  # makes on purpose to something that doesn't exist (a proposed command,
  # a placeholder) is allowlisted with the reason, and an allowlist entry
  # that starts to resolve, or that no doc mentions any more, is itself
  # reported, so the list can't go stale the way the docs did.
  class DocReferences
    Finding = Data.define(:path, :line, :reference, :problem)

    CONFIG = 'gem/bsv-wallet/tasks/docs_guard/doc_references.yml'

    CODE_SPAN = /`([^`\n]+)`/
    CONSTANT = /[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*/
    METHOD = /[a-z_][A-Za-z0-9_]*[?!=]?/
    # A whole span: +Engine::Hydrator+, +Store#find_proof+, +BRC29.key_id(prefix, suffix)+.
    CODE_REFERENCE = /\A(?:::)?(?<const>#{CONSTANT})(?:(?<sep>[#.])(?<meth>#{METHOD}))?(?:\(.*\))?\z/
    # Inside a fence with no language (diagrams), only qualified names are
    # unambiguous enough to check.
    DIAGRAM_REFERENCE = /(?<![\w:])(?<const>[A-Z]\w*(?:::[A-Z]\w*)+)(?:(?<sep>#)(?<meth>#{METHOD}))?/
    BINARY = %r{\Abin/(?<name>[a-z][a-z0-9_]*)\b}
    PATH_TAIL = /[\w-]\.(?:rb|rake|md|yml|yaml|json|sql)/
    FILE_PATH = %r{\A(?![~/])(?!\.\.?/)(?!\w+://)[\w./-]*#{PATH_TAIL}\z}
    RELATIVE_PATH = %r{\A\.\.?/[\w./-]*#{PATH_TAIL}\z}
    MIGRATION = %r{\bmigrations?\s+(?<number>\d{3})\b|\b(?<number>\d{3})_[a-z][a-z0-9_]*\.rb\b|\bdb/migrations/(?<number>\d{3})\b}
    FILE_EXTENSIONS = %w[md rb rake yml yaml json lock txt sh html css js toml sql].freeze

    # @param config_path [String] the YAML scan list and allowlist
    # @param root [String] repository root
    # @param index [CodeIndex]
    # @param files [Array<String>] every file in the repository, relative to +root+
    def self.from_file(config_path, root:, index:, files:)
      config = YAML.safe_load_file(config_path)
      new(root: root, index: index, files: files,
          scan: config.fetch('scan'), skip: config.fetch('skip', []), allow: config.fetch('allow', {}))
    end

    def initialize(root:, index:, files:, scan:, skip: [], allow: {})
      @root = File.expand_path(root)
      @index = index
      @files = files
      @scan = scan
      @skip = skip
      @allow = allow
    end

    def findings
      used = Set.new
      found = markdown_files.flat_map { |path| findings_in(path, used) }
      found + stale_allowances(used)
    end

    private

    def markdown_files
      @files.select { |f| f.end_with?('.md') && scanned?(f) }.sort
    end

    def scanned?(path)
      @scan.any? { |s| path == s || path.start_with?("#{s}/") } &&
        @skip.none? { |s| path == s || path.start_with?("#{s}/") }
    end

    # @param used [Set<String>] collects the allowlist entries that
    #   suppressed a finding
    def findings_in(path, used)
      lines = File.read(File.join(@root, path), encoding: 'UTF-8').scrub.lines
      kinds = line_kinds(lines)
      dir = File.dirname(path)
      lines.each_with_index.flat_map do |text, index|
        next [] if DocsGuard.dated_entry?(text)

        problems_in(text, kinds[index], dir).filter_map do |reference, problem|
          if @allow.key?(reference)
            used << reference
            next
          end

          Finding.new(path: path, line: index + 1, reference: reference, problem: problem)
        end
      end
    end

    def problems_in(text, kind, dir)
      case kind
      when :prose
        text.scan(CODE_SPAN).flatten.filter_map { |span| check_span(span.strip, dir) } + check_migrations(text)
      when :diagram
        text.to_enum(:scan, DIAGRAM_REFERENCE).map { Regexp.last_match }.filter_map { |m| check_code(m) }
      else
        []
      end
    end

    # Paths come before code: +CLAUDE.md+ also reads as +Const.method+.
    #
    # @return [Array(String, String), nil] the reference and what's wrong with it
    def check_span(span, dir)
      if (m = BINARY.match(span))
        check_binary(m[:name])
      elsif (m = MIGRATION.match(span))
        check_migration_file(span, m[:number])
      elsif FILE_PATH.match?(span) || RELATIVE_PATH.match?(span)
        check_path(span, dir)
      elsif (m = CODE_REFERENCE.match(span))
        check_code(m)
      end
    end

    def check_code(match)
      const = match[:const]
      sep = match[:sep]
      meth = match[:meth]
      return if sep.nil? && !const.include?('::')
      return if sep == '.' && FILE_EXTENSIONS.include?(meth)
      return if @index.resolves?(const, sep, meth)

      ["#{const}#{sep}#{meth}", describe_unresolved(const, sep, meth)]
    end

    def describe_unresolved(const, sep, meth)
      candidates = @index.candidates_for(const)
      return "no constant #{const} in the loaded code" if candidates.empty?

      kind = sep == '#' ? 'instance method' : 'class or module method'
      "no #{kind} #{meth} on #{candidates.join(', ')}"
    end

    def check_binary(name)
      return if @files.include?("gem/bsv-wallet/bin/#{name}")

      ["bin/#{name}", "no executable gem/bsv-wallet/bin/#{name}"]
    end

    # A path written from the doc's own directory (+../concepts/x.md+)
    # must exist exactly there; any other path may name a file anywhere by
    # its trailing segments (+engine/tx_builder.rb+).
    def check_path(path, dir)
      found = if RELATIVE_PATH.match?(path)
                @files.include?(File.expand_path(path, "/#{dir}").delete_prefix('/'))
              else
                @files.any? { |f| f == path || f.end_with?("/#{path}") }
              end
      [path, 'no such file in the repository'] unless found
    end

    # A full migration file name must exist. A missing number is reported by
    # +check_migrations+, which reads the whole line, so it isn't reported twice.
    def check_migration_file(span, number)
      return unless span.end_with?('.rb')

      dir = 'gem/bsv-wallet/db/migrations'
      return unless @files.any? { |f| f.start_with?("#{dir}/#{number}_") }

      name = File.basename(span)
      [span, "no #{dir}/#{name}"] unless @files.include?("#{dir}/#{name}")
    end

    def check_migrations(text)
      text.to_enum(:scan, MIGRATION).map { Regexp.last_match[:number] }.uniq.filter_map do |number|
        next if @files.any? { |f| f.start_with?("gem/bsv-wallet/db/migrations/#{number}_") }

        ["migration #{number}", "no gem/bsv-wallet/db/migrations/#{number}_*.rb"]
      end
    end

    # Each line is :prose, :code (inside a fence with a language, or a fence
    # marker) or :diagram (inside a fence with no language: ASCII diagrams,
    # where class names drift as easily as in prose).
    def line_kinds(lines)
      DocsGuard.each_line_with_fence(lines).map do |_line, _index, fence, edge|
        if fence.nil?
          :prose
        elsif edge || !fence.info.empty?
          :code
        else
          :diagram
        end
      end
    end

    # An entry that suppressed nothing is stale: what it names resolves
    # now, or no doc names it as a whole reference on a checked line.
    def stale_allowances(used)
      @allow.except(*used).map do |name, reason|
        problem = if check_span(name, '.').nil?
                    "allowlisted (#{reason}) but now resolves; remove it"
                  else
                    "allowlisted (#{reason}) but no doc mentions it; remove it"
                  end
        Finding.new(path: CONFIG, line: 1, reference: name, problem: problem)
      end
    end
  end
end
