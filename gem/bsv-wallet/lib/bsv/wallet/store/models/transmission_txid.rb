# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        # Pure membership: a wtxid carried by a transmission's BEEF. The
        # per-counterparty known set (BeefParty trimming) is the union of
        # these rows across all of a counterparty's transmissions. Rows are
        # written only on ack (Store#mark_transmission_acked), never on
        # the transmission record itself — see HLR #385 two-phase note.
        class TransmissionTxid < Sequel::Model
          many_to_one :transmission, class: 'BSV::Wallet::Store::Models::Transmission'
        end
      end
    end
  end
end
