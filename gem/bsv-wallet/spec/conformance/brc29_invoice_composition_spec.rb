# frozen_string_literal: true

require_relative '../spec_helper'

# Cross-implementation reference vector for BRC-29 invoice composition.
#
# +expected_child_pub_hex+ was produced by running ts-stack +@bsv/sdk+
# v2.1.6 (commit-pinned via +/opt/js/ts-stack+ checkout) against the same
# inputs. The spec asserts byte equality against that external value —
# the Ruby wallet is not allowed to "prove" the invoice format by feeding
# its own derivation back into itself.
#
# Reference: to reproduce the +expected_child_pub_hex+ literal,
#
#   cd /opt/js/ts-stack/packages/sdk && pnpm install && pnpm run build:ts
#   node -e '
#     import("/opt/js/ts-stack/packages/sdk/dist/esm/src/wallet/KeyDeriver.js")
#       .then(({ KeyDeriver }) => import("/opt/js/ts-stack/packages/sdk/dist/esm/src/primitives/index.js")
#         .then(({ PrivateKey }) => {
#           const sender = PrivateKey.fromHex("583755110a8c059de5cd81b8a04e1be884c46083ade3f779c1e022f6f89da94c");
#           const recipientPub = PrivateKey.fromHex("6a1751169c111b4667a6539ee1be6b7cd9f6e9c8fe011a5f2fe31e03a15e0ede").toPublicKey().toString();
#           const kd = new KeyDeriver(sender);
#           console.log(kd.derivePublicKey([2, "3241645161d8"], "IBioA4D/OaE= f3WCaUmnN9U=", recipientPub).toString());
#         }));'
#   # => 02466d6e720a88feff6b3ee92883db08282eb49df75275dada7e7dd822ded1f203
#
# The sender's private key is taken from BRC-42 §"For Testing Public Key
# Derivation" vector 1 (+/opt/BRCs/key-derivation/0042.md:115+); the
# recipient's private key is taken from BRC-42 §"For Testing Private Key
# Derivation" vector 1 (+/opt/BRCs/key-derivation/0042.md:79+). The prefix
# and suffix are deliberately the +invoiceNumber+ values from those two
# vectors so a reviewer can verify the key material without leaving the
# BRC-42 spec text.
RSpec.describe 'BRC-29 invoice composition reference vector' do # rubocop:disable RSpec/DescribeClass
  let(:sender_priv_hex) do
    '583755110a8c059de5cd81b8a04e1be884c46083ade3f779c1e022f6f89da94c'
  end
  let(:recipient_priv_hex) do
    '6a1751169c111b4667a6539ee1be6b7cd9f6e9c8fe011a5f2fe31e03a15e0ede'
  end
  let(:derivation_prefix) { 'IBioA4D/OaE=' }
  let(:derivation_suffix) { 'f3WCaUmnN9U=' }

  let(:expected_key_id) { 'IBioA4D/OaE= f3WCaUmnN9U=' }
  let(:expected_invoice_number) { '2-3241645161d8-IBioA4D/OaE= f3WCaUmnN9U=' }
  let(:expected_child_pub_hex) do
    '02466d6e720a88feff6b3ee92883db08282eb49df75275dada7e7dd822ded1f203'
  end

  let(:sender_priv) { BSV::Primitives::PrivateKey.from_hex(sender_priv_hex) }
  let(:recipient_priv) { BSV::Primitives::PrivateKey.from_hex(recipient_priv_hex) }
  let(:sender_pub_hex) { sender_priv.public_key.to_hex }
  let(:recipient_pub_hex) { recipient_priv.public_key.to_hex }

  let(:sender_deriver) { BSV::Wallet::KeyDeriver.new(private_key: sender_priv) }
  let(:recipient_deriver) { BSV::Wallet::KeyDeriver.new(private_key: recipient_priv) }

  describe 'BRC29.key_id composition' do
    it 'joins prefix and suffix into the spec-mandated key_id' do
      expect(BSV::Wallet::BRC29.key_id(derivation_prefix, derivation_suffix))
        .to eq(expected_key_id)
    end

    it 'composes the BRC-43 invoice number byte-exactly' do
      key_id = BSV::Wallet::BRC29.key_id(derivation_prefix, derivation_suffix)
      protocol_id = BSV::Wallet::BRC29::PROTOCOL_ID
      invoice = "#{protocol_id[0]}-#{protocol_id[1]}-#{key_id}"
      expect(invoice).to eq(expected_invoice_number)
    end
  end

  describe 'sender-side derivation' do
    # +for_self: true+ on the Ruby wallet's +KeyDeriver+ asks for the
    # *counterparty's* child public key (the one the recipient would have
    # derived themselves). This is the BRC-29 sender's view: I want the
    # recipient's child pubkey so I can pay it. Note that the Ruby
    # +for_self+ flag is named inversely to ts-stack's +forSelf+ — the
    # underlying BRC-42 derivation is the same.
    it 'matches the external @bsv/sdk reference for the child public key' do
      derived = sender_deriver.derive_public_key(
        protocol_id: BSV::Wallet::BRC29::PROTOCOL_ID,
        key_id: BSV::Wallet::BRC29.key_id(derivation_prefix, derivation_suffix),
        counterparty: recipient_pub_hex,
        for_self: true
      )
      expect(derived.unpack1('H*')).to eq(expected_child_pub_hex)
    end
  end

  describe 'recipient-side derivation (symmetric)' do
    it 'recovers a private key whose public key matches the external reference' do
      child_priv = recipient_deriver.derive_private_key(
        protocol_id: BSV::Wallet::BRC29::PROTOCOL_ID,
        key_id: BSV::Wallet::BRC29.key_id(derivation_prefix, derivation_suffix),
        counterparty: sender_pub_hex
      )
      expect(child_priv.public_key.to_hex).to eq(expected_child_pub_hex)
    end
  end

  describe 'rejection vectors' do
    it 'rejects a trailing-space prefix' do
      expect { BSV::Wallet::BRC29.key_id('abc ', 'xyz') }
        .to raise_error(BSV::Wallet::BRC29::InvalidDerivationToken)
    end

    it 'rejects an embedded-space suffix' do
      expect { BSV::Wallet::BRC29.key_id('abc', 'xyz def') }
        .to raise_error(BSV::Wallet::BRC29::InvalidDerivationToken)
    end

    it 'rejects an empty prefix' do
      expect { BSV::Wallet::BRC29.key_id('', 'xyz') }
        .to raise_error(BSV::Wallet::BRC29::InvalidDerivationToken)
    end
  end
end
