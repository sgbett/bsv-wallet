# frozen_string_literal: true

source 'https://rubygems.org'

gemspec path: 'gem/bsv-wallet'
gemspec path: 'gem/bsv-wallet-postgres'

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
