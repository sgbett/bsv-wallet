# frozen_string_literal: true

# Documentation drift guards (#545), run by the CI job "Docs guards".
#
#   bundle exec rake docs:retired_terms   # vocabulary the glossary retires
#   bundle exec rake docs:references      # classes, methods, bin/ names, paths that don't exist

require 'open3'
require_relative 'docs_guard'

module DocsGuard
  ROOT = File.expand_path('../../..', __dir__)
  GLOSSARY = 'docs/reference/glossary.md#retired-terms'

  module_function

  def report(findings, title)
    findings.each do |path, line, message|
      if ENV['GITHUB_ACTIONS']
        puts "::error file=#{path},line=#{line},title=#{title}::#{message}"
      else
        warn "#{path}:#{line}: #{message}"
      end
    end
  end

  def tracked_files
    out, status = Open3.capture2('git', '-C', ROOT, 'ls-files', '-z')
    abort 'docs guard: git ls-files failed' unless status.success?
    out.split("\0")
  end
end

namespace :docs do
  desc 'Fail on vocabulary the glossary retires (docs/reference/glossary.md, Retired terms)'
  task :retired_terms do
    Regexp.timeout = 1.0
    check = DocsGuard::RetiredTerms.from_file(File.join(__dir__, 'docs_guard/retired_terms.yml'), root: DocsGuard::ROOT)
    findings = check.findings
    violations = findings.reject { |f| f.term.pending }
    problems = check.problems

    DocsGuard.report(violations.map do |f|
      [f.path, f.line, "\"#{f.term.retired}\" is retired; use #{f.term.use_instead} (#{DocsGuard::GLOSSARY})"]
    end, 'Retired term')
    DocsGuard.report(problems.map { |p| ['gem/bsv-wallet/tasks/docs_guard/retired_terms.yml', 1, p] }, 'Term list')

    pending = findings.select { |f| f.term.pending }.group_by(&:term)
    pending.each { |term, hits| puts "pending (#{term.pending}): #{term.retired} — #{hits.size} hit(s), not enforced yet" }
    abort "docs:retired_terms — #{violations.size + problems.size} problem(s)" unless violations.empty? && problems.empty?

    puts 'docs:retired_terms OK'
  end

  desc 'Fail on docs that name a class, method, bin/ executable, file or migration that does not exist'
  task :references do
    Regexp.timeout = 1.0
    lib = File.expand_path('../lib', __dir__)
    DocsGuard::CodeIndex.load_all!(lib, namespaces: %w[BSV])
    index = DocsGuard::CodeIndex.new(local_root: lib)
    check = DocsGuard::DocReferences.from_file(
      File.join(__dir__, 'docs_guard/doc_references.yml'),
      root: DocsGuard::ROOT, index: index, files: DocsGuard.tracked_files
    )
    findings = check.findings

    DocsGuard.report(findings.map { |f| [f.path, f.line, "`#{f.reference}`: #{f.problem}"] }, 'Stale reference')
    abort "docs:references — #{findings.size} stale reference(s)" unless findings.empty?

    puts 'docs:references OK'
  end
end
