# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require_relative '../../../tasks/docs_guard'

RSpec.describe DocsGuard::DocReferences do
  let(:root) { Dir.mktmpdir('doc-references') }
  let(:index) { DocsGuard::CodeIndex.new([DocsGuardFixture::Engine, DocsGuardFixture::Engine::Hydrator]) }
  let(:repository_files) do
    %w[
      gem/bsv-wallet/bin/wallet
      gem/bsv-wallet/lib/bsv/wallet/engine/tx_builder.rb
      gem/bsv-wallet/db/migrations/001_create_schema.rb
      gem/bsv-wallet/db/migrations/002_triggers.rb
      docs/concepts/architecture.md
      CLAUDE.md
      .architecture/principles.md
    ]
  end

  before do
    stub_const('DocsGuardFixture::Engine::Hydrator', Class.new { def wire; end })
    FileUtils.mkdir_p(File.join(root, 'docs/concepts'))
    File.write(File.join(root, 'docs/concepts/architecture.md'), "# Architecture\n")
  end

  after { FileUtils.rm_rf(root) }

  def findings_for(markdown, allow: {}, path: 'docs/reference/a.md')
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, markdown)
    described_class.new(root: root, index: index, files: repository_files + [path], scan: ['docs'], allow: allow).findings
  end

  def references(markdown, **opts)
    findings_for(markdown, **opts).map(&:reference)
  end

  it 'reports an inline-code method reference that does not resolve, with its line' do
    findings = findings_for("ok\nSee `Hydrator#replace_known_ancestors!` here.\n")

    expect(findings.map { |f| [f.line, f.reference, f.problem] })
      .to eq([[2, 'Hydrator#replace_known_ancestors!', 'no instance method replace_known_ancestors! on DocsGuardFixture::Engine::Hydrator']])
  end

  it 'accepts references that resolve, including a call with arguments' do
    expect(references("`Engine::Hydrator`, `Hydrator#wire` and `Hydrator.new(store)`\n")).to be_empty
  end

  it 'reports a qualified constant nothing defines' do
    expect(references("`Interface::Transmission`\n")).to eq(['Interface::Transmission'])
  end

  it 'ignores bare words and file names that look like Const.method' do
    expect(references("`MINED`, `DATABASE_URL`, `Hydrator`, `Gemfile.lock`\n")).to be_empty
  end

  it 'checks bin/ executables' do
    expect(references("`bin/wallet send` but not `bin/create alice`\n")).to eq(['bin/create'])
  end

  describe 'file paths' do
    it 'accepts a path that names a file by its trailing segments' do
      expect(references("`engine/tx_builder.rb`\n")).to be_empty
    end

    it 'reports a path to a file that is not there' do
      expect(references("`engine/beef_importer.rb`\n")).to eq(['engine/beef_importer.rb'])
    end

    it 'checks a capitalised file name as a path, not as Const.method' do
      expect(references("`CLAUDE.md` but not `README.md` or `Gone.rb`\n")).to eq(%w[README.md Gone.rb])
    end

    it 'checks a path under a dot directory from the repository root' do
      expect(references("`.architecture/principles.md` but not `.architecture/gone.md`\n")).to eq(['.architecture/gone.md'])
    end

    it 'resolves a relative path from the doc' do
      expect(references("`../concepts/architecture.md` and `../concepts/gone.md`\n")).to eq(['../concepts/gone.md'])
    end
  end

  it 'checks a full migration file name when its number exists' do
    expect(references("`001_create_schema.rb`, `001_removed.rb` and `db/migrations/002_gone.rb`\n"))
      .to eq(%w[001_removed.rb db/migrations/002_gone.rb])
  end

  it 'reports a migration file with a missing number once, as the number' do
    expect(references("`005_gone.rb`\n")).to eq(['migration 005'])
  end

  it 'reports a migration number with no migration file, in prose as well as in code' do
    expect(references("CHECKs in migration 003 and `010_sse_cursors.rb`, not migration 001.\n"))
      .to eq(['migration 003', 'migration 010'])
  end

  it 'skips fences with a language and checks qualified names in diagram fences' do
    markdown = "```ruby\nEngine::Gone.new\n```\n\n```\n  Engine::Hydrator → Engine::Gone\n```\n"

    expect(findings_for(markdown).map { |f| [f.line, f.reference] }).to eq([[6, 'Engine::Gone']])
  end

  it 'closes a fence only on its own marker, as long or longer' do
    markdown = "~~~markdown\n```ruby\n`Engine::Gone` here\n~~~~\n`Engine::Gone`\n"

    expect(findings_for(markdown).map(&:line)).to eq([5])
  end

  it 'skips dated change-log entries' do
    expect(references("- *2026-06-24* — renamed `Engine::BeefImporter`\n")).to be_empty
  end

  describe 'the allowlist' do
    it 'suppresses an allowlisted reference' do
      expect(references("`bin/brc100`\n", allow: { 'bin/brc100' => 'proposed, #431' })).to be_empty
    end

    it 'reports an entry no doc mentions any more' do
      findings = findings_for("nothing here\n", allow: { 'bin/brc100' => 'proposed, #431' })

      expect(findings.map(&:problem)).to contain_exactly(a_string_including('no doc mentions it'))
    end

    it 'reports an entry a doc names only inside fenced code' do
      findings = findings_for("```sh\nopen `foo.md`\n```\n", allow: { 'foo.md' => 'placeholder' })

      expect(findings.map(&:problem)).to contain_exactly(a_string_including('no doc mentions it'))
    end

    it 'reports an entry a doc names only as part of a longer reference' do
      findings = findings_for("`barfoo.md`\n", allow: { 'foo.md' => 'placeholder' })

      expect(findings.map(&:reference)).to contain_exactly('barfoo.md', 'foo.md')
    end

    it 'reports an entry that now resolves' do
      findings = findings_for("`bin/wallet`\n", allow: { 'bin/wallet' => 'proposed' })

      expect(findings.map(&:problem)).to contain_exactly(a_string_including('now resolves'))
    end
  end
end
