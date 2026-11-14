# frozen_string_literal: true

require 'ripper'

# Core (Engine, Store and the interfaces) sits beneath the BRC-100 wrapper:
# it calls Engine primitives and never reaches back up through the wrapper.
RSpec.describe 'core boundary' do # rubocop:disable RSpec/DescribeClass
  def self.lib_dir
    File.expand_path('../../../lib/bsv/wallet', __dir__)
  end

  def self.core_files
    %w[engine.rb engine/**/*.rb store.rb store/**/*.rb interface.rb interface/**/*.rb]
      .flat_map { |pattern| Dir.glob(File.join(lib_dir, pattern)) }
      .map { |path| path.delete_prefix("#{lib_dir}/") }
  end

  def self.wrapper_references(source, file)
    wrapper_tokens = { on_ident: 'brc100', on_ivar: '@brc100', on_const: 'BRC100' }
    lines = source.lines
    Ripper.lex(source).filter_map do |(line, _column), event, token, _state|
      next unless wrapper_tokens[event] == token

      { file: file, line: line, token: token, text: lines[line - 1].strip }
    end
  end

  def self.core_references
    @core_references ||= core_files.flat_map do |file|
      wrapper_references(File.read(File.join(lib_dir, file)), file)
    end
  end

  # Engine#brc100 is the deliberate exception: it is how callers reach the
  # wrapper. The rule is that core never calls through it.
  let(:allowed) do
    [
      { file: 'engine.rb', text: 'def brc100' },
      { file: 'engine.rb', text: '@brc100 ||= BSV::Wallet::BRC100.new(self)' }
    ]
  end

  let(:core_files) { self.class.core_files }
  let(:references) { self.class.core_references }

  def allowed?(reference)
    allowed.include?(reference.slice(:file, :text))
  end

  it 'scans the core sources, Engine included' do
    expect(core_files).not_to be_empty
    expect(core_files).to include('engine.rb', 'engine/action.rb', 'store.rb', 'interface.rb')
  end

  it 'refers to the BRC-100 wrapper only in the Engine#brc100 accessor' do
    offending = references.reject { |reference| allowed?(reference) }

    expect(offending).to be_empty, lambda {
      listed = offending.map { |r| "  lib/bsv/wallet/#{r[:file]}:#{r[:line]}  #{r[:text]}" }
      "core reaches the BRC-100 wrapper at:\n#{listed.join("\n")}"
    }
  end

  it 'sees every allow-listed accessor line' do
    unseen = allowed.reject { |entry| references.any? { |reference| reference.slice(:file, :text) == entry } }

    expect(unseen).to be_empty
  end

  it 'flags code references and ignores comments and strings' do
    snippet = <<~RUBY
      brc100.list_actions(labels: [])
      @brc100&.x
      self.brc100
      # brc100.foo
      "brc100.bar"
    RUBY

    flagged = self.class.wrapper_references(snippet, 'snippet.rb').map { |reference| reference.values_at(:line, :token) }

    expect(flagged).to eq([[1, 'brc100'], [2, '@brc100'], [3, 'brc100']])
  end
end
