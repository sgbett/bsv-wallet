# frozen_string_literal: true

require_relative 'lib/bsv/wallet/version'

Gem::Specification.new do |spec|
  spec.name    = 'bsv-wallet'
  spec.version = BSV::Wallet::VERSION
  spec.authors = ['Simon Bettison']

  spec.summary     = 'BRC-100 compliant BSV wallet'
  spec.description = 'A Ruby implementation of the BRC-100 BSV wallet interface — ' \
                     'transaction management, key derivation, encryption, ' \
                     'certificates, and identity verification.'
  spec.homepage    = 'https://github.com/sgbett/bsv-ruby-sdk'
  spec.license     = 'LicenseRef-OpenBSV'

  spec.required_ruby_version = '>= 3.0'

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/master/gem/bsv-wallet/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir.chdir(__dir__) do
    Dir.glob('lib/**/*')
  end + %w[LICENSE CHANGELOG.md]
  spec.require_paths = ['lib']

  spec.add_dependency 'bsv-sdk'
end
