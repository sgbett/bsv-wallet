# frozen_string_literal: true

source 'https://rubygems.org'

gemspec path: 'gem/bsv-wallet'
gemspec path: 'gem/bsv-wallet-postgres'

# Local SDK — remove once published to rubygems
gem 'bsv-sdk', path: '/opt/ruby/bsv-ruby-sdk/gem/bsv-sdk'

group :development, :test do
  gem 'rake'
  gem 'rspec', '~> 3.13'
  gem 'rubocop', '~> 1.75', require: false
  gem 'rubocop-rspec', '~> 3.9', require: false
  gem 'simplecov', require: false
  gem 'simplecov-cobertura', require: false
  gem 'yard'
  gem 'yard-markdown'

  # Postgres adapter test dependencies
  gem 'rack-test', '~> 2.1'
end
