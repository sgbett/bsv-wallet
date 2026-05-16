# frozen_string_literal: true

module BSV
  module Wallet
    # PostgreSQL adapter for bsv-wallet.
    #
    # Usage:
    #   BSV::Wallet::Postgres::Store::Connection.connect('postgres://...')
    #   BSV::Wallet::Postgres::Store::Connection.migrate!
    #   store = BSV::Wallet::Postgres::Store::Postgres.new
    module Postgres
      autoload :VERSION, 'bsv/wallet/postgres/version'
      autoload :Store,   'bsv/wallet/postgres/store'
    end
  end
end
