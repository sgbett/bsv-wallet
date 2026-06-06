# frozen_string_literal: true

require 'spec_helper'
require 'bsv-wallet'

RSpec.describe BSV::Wallet::Engine::InputSource do
  let(:input) { BSV::Transaction::TransactionInput.new(prev_wtxid: ("\x00" * 32), prev_tx_out_index: 0) }
  let(:locking_script_bin) { ['76a9146d8b7fefb1d2eb561205dfa920fa51f24c7d821888ac'].pack('H*') }
  let(:source) do
    {
      source_satoshis: 1_000_000,
      source_locking_script: locking_script_bin
    }
  end

  describe '.attach!' do
    it 'sets source_satoshis on the input' do
      described_class.attach!(input, source)
      expect(input.source_satoshis).to eq(1_000_000)
    end

    it 'wraps source_locking_script bytes in BSV::Script::Script' do
      described_class.attach!(input, source)
      expect(input.source_locking_script).to be_a(BSV::Script::Script)
    end

    it 'preserves the locking script bytes' do
      described_class.attach!(input, source)
      expect(input.source_locking_script.to_binary).to eq(locking_script_bin)
    end
  end
end
