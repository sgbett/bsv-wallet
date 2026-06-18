# frozen_string_literal: true

require_relative '../../spec_helper'

using BSV::Wallet::Txid

RSpec.describe BSV::Wallet::Txid do
  describe 'String#to_dtxid' do
    it 'reverses wire-order bytes and hex-encodes (wtxid → dtxid)' do
      wtxid = "\x01\x02\x03\x04".b
      expect(wtxid.to_dtxid).to eq('04030201')
    end

    it 'round-trips against the open-coded idiom for a 32-byte wtxid' do
      wtxid = SecureRandom.random_bytes(32)
      expect(wtxid.to_dtxid).to eq(wtxid.reverse.unpack1('H*'))
    end

    it 'produces 64-char display-order hex for a 32-byte wtxid' do
      dtxid = SecureRandom.random_bytes(32).to_dtxid
      expect(dtxid).to match(/\A[0-9a-f]{64}\z/)
    end
  end
end
