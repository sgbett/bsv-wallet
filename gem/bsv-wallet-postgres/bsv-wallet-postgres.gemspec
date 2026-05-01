# frozen_string_literal: true

require_relative 'lib/bsv/wallet/postgres/version'

Gem::Specification.new do |spec|
  spec.name    = 'bsv-wallet-postgres'
  spec.version = BSV::Wallet::Postgres::VERSION
  spec.authors = ['Simon Bettison']

  spec.summary     = 'PostgreSQL adapter for bsv-wallet'
  spec.description = 'Sequel models, migrations, and concrete Store/BroadcastQueue/ProofStore ' \
                     'implementations for the bsv-wallet gem, backed by PostgreSQL.'
  spec.homepage    = 'https://github.com/sgbett/bsv-wallet'
  spec.license     = 'LicenseRef-OpenBSV'

  spec.required_ruby_version = '>= 3.0'

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/master/gem/bsv-wallet-postgres/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir.chdir(__dir__) do
    Dir.glob('lib/**/*') + Dir.glob('db/**/*')
  end + %w[LICENSE CHANGELOG.md]
  spec.require_paths = ['lib']

  spec.add_dependency 'bsv-wallet'
  spec.add_dependency 'sequel', '~> 5.0'
  spec.add_dependency 'pg'
end
