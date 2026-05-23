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
      end
    end
  end
end
