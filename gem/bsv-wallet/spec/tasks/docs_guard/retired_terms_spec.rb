# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require_relative '../../../tasks/docs_guard'

RSpec.describe DocsGuard::RetiredTerms do
  let(:root) { Dir.mktmpdir('retired-terms') }
  let(:substrate) { term('substrate', '\bsubstrate\b', row: 'substrate') }

  after { FileUtils.rm_rf(root) }

  def write(path, content)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def term(retired, pattern, **opts)
    described_class::Term.new(retired: retired, pattern: Regexp.new(pattern, Regexp::IGNORECASE),
                              use_instead: 'something else', row: opts[:row],
                              exempt: opts.fetch(:exempt, []), pending: opts[:pending])
  end

  def check(terms: [substrate], **opts)
    described_class.new(root: root, scan: %w[docs lib CLAUDE.md], terms: terms, **opts)
  end

  it 'reports a retired term with its path and line, whatever its case' do
    write('docs/a.md', "fine\nThe Substrate under both\n")

    expect(check.violations.map { |f| [f.path, f.line, f.term.retired] }).to eq([['docs/a.md', 2, 'substrate']])
  end

  it 'scans code comments and single files named in the scan list' do
    write('lib/x.rb', "# shared substrate\n")
    write('CLAUDE.md', "the substrate\n")

    expect(check.violations.map(&:path)).to contain_exactly('lib/x.rb', 'CLAUDE.md')
  end

  it 'ignores paths outside the scan list and under a skipped prefix' do
    write('spec/a_spec.rb', "# substrate\n")
    write('docs/reference/external/BRC.md', "substrate\n")

    expect(check(skip: ['docs/reference/external']).violations).to be_empty
  end

  it 'exempts a dated change-log entry' do
    write('docs/a.md', "- *2026-06-25* — renamed the substrate\n")

    expect(check.violations).to be_empty
  end

  describe 'exempt sections' do
    let(:sections) { [described_class::Section.new('CLAUDE.md', 'Vocabulary')] }

    it 'exempts the named section only, up to the next heading at its level' do
      write('CLAUDE.md', <<~MD)
        ## Vocabulary

        Don't write substrate.

        ### Detail

        Still the substrate rule.

        ## Security focus

        The substrate slipped back in here.
      MD

      expect(check(exempt_sections: sections).violations.map(&:line)).to eq([11])
    end

    it 'ignores # comment lines inside a fence when finding where the section ends' do
      write('CLAUDE.md', "## Vocabulary\n\n```sh\n# not a heading\n```\n\nsubstrate is retired\n")

      expect(check(exempt_sections: sections).violations).to be_empty
    end
  end

  it 'honours a per-term exempt path' do
    write('lib/brc100.rb', "no_send: false\n")
    write('lib/engine.rb', "no_send: false\n")
    no_send = term('no_send', '\bno_send\b', exempt: ['lib/brc100.rb'])

    expect(check(terms: [no_send]).violations.map(&:path)).to eq(['lib/engine.rb'])
  end

  it 'reports a pending term without failing on it' do
    write('lib/engine.rb', "no_send: false\n")
    no_send = term('no_send', '\bno_send\b', pending: '#548')
    guard = check(terms: [no_send])

    expect([guard.findings.size, guard.violations, guard.problems]).to eq([1, [], []])
  end

  describe 'problems with the term list itself' do
    it 'fails a pending term once it has no hits left' do
      write('lib/engine.rb', "broadcast_intent: :none\n")
      no_send = term('no_send', '\bno_send\b', pending: '#548')

      expect(check(terms: [no_send]).problems).to contain_exactly(a_string_including('no hits left', '#548'))
    end

    it 'fails an exempt path that does not exist' do
      no_send = term('no_send', '\bno_send\b', exempt: ['lib/gone.rb'])

      expect(check(terms: [no_send]).problems).to contain_exactly(a_string_including('lib/gone.rb'))
    end

    it 'fails a glossary row that is neither mapped to a term nor listed as manual' do
      write('docs/reference/glossary.md', <<~MD)
        ## Retired terms

        | Retired | Use instead |
        |---|---|
        | substrate | the Hydrator |
        | staged, for unpromoted outputs | unpromoted |
        | widget | gadget |

        ## Next
      MD

      problems = check(manual_rows: ['staged, for unpromoted outputs']).problems
      expect(problems).to contain_exactly(a_string_including('"widget"'))
    end
  end

  describe 'the repository term list' do
    let(:config) { File.expand_path('../../../tasks/docs_guard/retired_terms.yml', __dir__) }
    let(:repository) { File.expand_path('../../../../..', __dir__) }

    it 'loads, and maps every glossary row' do
      guard = described_class.from_file(config, root: repository)

      expect(guard.problems.grep(/glossary row/)).to be_empty
    end
  end
end
