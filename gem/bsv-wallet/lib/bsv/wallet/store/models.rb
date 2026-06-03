# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      # Namespace for all Sequel model classes.
      #
      # Models are autoloaded to defer class body evaluation until first
      # access — Sequel::Model needs a database connection to read schema
      # metadata, which isn't available at require time.
      module Models
        # Allow model classes to be defined before their tables exist.
        # Postgres raises PG::UndefinedTable during class body evaluation
        # if the table is missing; this defers schema introspection until
        # first query. bind_models! (called after migrate!) re-binds
        # datasets to the live database.
        Sequel::Model.require_valid_table = false

        # Shared model concern (eager — no DB dependency)
        require_relative 'models/display_txid'

        autoload :Block,            'bsv/wallet/store/models/block'
        autoload :TxProof,          'bsv/wallet/store/models/tx_proof'
        autoload :Action,           'bsv/wallet/store/models/action'
        autoload :Broadcast,        'bsv/wallet/store/models/broadcast'
        autoload :Basket,           'bsv/wallet/store/models/basket'
        autoload :Output,           'bsv/wallet/store/models/output'
        autoload :Spendable,        'bsv/wallet/store/models/spendable'
        autoload :OutputDetail,     'bsv/wallet/store/models/output_detail'
        autoload :OutputBasket,     'bsv/wallet/store/models/output_basket'
        autoload :Input,            'bsv/wallet/store/models/input'
        autoload :Label,            'bsv/wallet/store/models/label'
        autoload :ActionLabel,      'bsv/wallet/store/models/action_label'
        autoload :Tag,              'bsv/wallet/store/models/tag'
        autoload :OutputTag,        'bsv/wallet/store/models/output_tag'
        autoload :Certificate,      'bsv/wallet/store/models/certificate'
        autoload :CertificateField, 'bsv/wallet/store/models/certificate_field'
        autoload :Setting,          'bsv/wallet/store/models/setting'
        autoload :SseCursor,        'bsv/wallet/store/models/sse_cursor'
      end
    end
  end
end
