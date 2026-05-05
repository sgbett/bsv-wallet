# Plan: HLR #5 — Engine: Crypto, Identity, Auth, Network

## Context

HLR #4 implemented the 7 transaction methods. This HLR completes the remaining 21 BRC-100 methods on the Engine. Most are thin — key management and crypto delegate to the SDK, certificates delegate to the Store, auth and network are configuration lookups.

Two methods (`network`, `version`) are already implemented from HLR #4.

**Source issue:** sgbett/bsv-wallet#5

**SDK primitives available:**
- `BSV::Primitives::PrivateKey#derive_child(public_key, invoice_number)` — BRC-42
- `BSV::Primitives::PublicKey#derive_child(private_key, invoice_number)` — BRC-42
- `BSV::Primitives::PrivateKey#derive_shared_secret(public_key)` — ECDH
- `BSV::Primitives::PrivateKey#sign(hash)` — ECDSA
- `BSV::Primitives::PublicKey#verify(hash, signature)` — ECDSA verify
- `BSV::Primitives::SymmetricKey#encrypt(plaintext)` / `#decrypt(data)` — AES-256-GCM
- `BSV::Primitives::EncryptedMessage.encrypt/decrypt` — BRC-2
- `BSV::Primitives::Digest.hmac_sha256(key, data)` — HMAC

---

## Approach

### Key Deriver

Inject a `key_deriver` at Engine construction. This object knows the wallet's private key and can derive child keys per BRC-42/43. All crypto methods delegate to it.

```ruby
# Minimal interface — wraps the wallet's master key
class KeyDeriver
  def initialize(private_key:, privileged_key: nil)
    @private_key = private_key
    @privileged_key = privileged_key
  end

  def identity_key
    @private_key.public_key
  end

  def derive_private_key(protocol_id:, key_id:, counterparty:, privileged: false)
    root = privileged && @privileged_key ? @privileged_key : @private_key
    invoice = build_invoice(protocol_id, key_id)
    counterparty_pub = resolve_counterparty(counterparty)
    root.derive_child(counterparty_pub, invoice)
  end

  def derive_public_key(protocol_id:, key_id:, counterparty:, for_self: false, privileged: false)
    if for_self
      derive_private_key(...).public_key
    else
      counterparty_pub = resolve_counterparty(counterparty)
      invoice = build_invoice(protocol_id, key_id)
      counterparty_pub.derive_child(@private_key, invoice)
    end
  end
end
```

The key deriver is an SDK-level concern — it may already exist in the SDK or we create it here. For HLR #5, we define the interface and a concrete implementation using SDK primitives.

### Method implementations

**Key Management (3 methods):**

`public_key` — two modes:
```ruby
def public_key(identity_key: false, protocol_id: nil, key_id: nil, ...)
  if identity_key
    { public_key: @key_deriver.identity_key }
  else
    pub = @key_deriver.derive_public_key(
      protocol_id: protocol_id, key_id: key_id,
      counterparty: counterparty, for_self: for_self, privileged: privileged
    )
    { public_key: pub }
  end
end
```

`reveal_counterparty_key_linkage` / `reveal_specific_key_linkage` — BRC-69 via SDK. Derive the linkage, encrypt for the verifier using BRC-72. Returns the encrypted linkage data.

**Cryptography (6 methods):**

All follow the same pattern:
1. Derive a symmetric key or signing key via the key_deriver
2. Perform the operation using SDK primitives
3. Return binary result

```ruby
def encrypt(plaintext:, protocol_id:, key_id:, counterparty: nil, ...)
  priv = @key_deriver.derive_private_key(protocol_id: protocol_id, key_id: key_id, counterparty: counterparty)
  counterparty_pub = @key_deriver.resolve_counterparty(counterparty)
  ciphertext = BSV::Primitives::EncryptedMessage.encrypt(plaintext, priv, counterparty_pub)
  { ciphertext: ciphertext }
end
```

Verify methods raise errors:
```ruby
def verify_hmac(data:, hmac:, ...)
  expected = create_hmac(data: data, ...)[:hmac]
  raise BSV::Wallet::InvalidHmacError unless secure_compare(expected, hmac)
  { valid: true }
end
```

**Certificates (6 methods):**

- `acquire_certificate` — `:direct` delegates to `@store.save_certificate`, `:issuance` is a TODO (requires HTTP to certifier URL)
- `list_certificates` — `@store.query_certificates`
- `prove_certificate` — derive revelation keys for the verifier's fields (BRC-52 keyring). SDK computation.
- `relinquish_certificate` — `@store.delete_certificate`
- `discover_by_identity_key` / `discover_by_attributes` — `@store.query_certificates` with adapted filters. External lookup is a future concern.

**Authentication (2 methods):**

```ruby
def authenticated?(originator: nil)
  { authenticated: !@key_deriver.nil? }
end

def wait_for_authentication(originator: nil)
  # In a real deployment: block until key is available
  # For now: return immediately if authenticated
  raise BSV::Wallet::Error.new('not authenticated') unless @key_deriver
  { authenticated: true }
end
```

**Network (2 methods):** Already implemented in HLR #4.

`height` and `header_for_height` need a chain data source. For now: delegate to ProofStore for headers we have, raise for unknown heights. Full chain sync is a future concern.

```ruby
def height(originator: nil)
  # TODO: integrate with chain data source
  raise BSV::Wallet::UnsupportedActionError, 'height'
end

def header_for_height(height:, originator: nil)
  # TODO: integrate with chain data source
  raise BSV::Wallet::UnsupportedActionError, 'header_for_height'
end
```

---

## Files to Modify/Create

```
gem/bsv-wallet/
  lib/bsv/wallet/engine.rb        ← MODIFY: add 19 methods (21 minus 2 already done)
  spec/bsv/wallet/engine_spec.rb  ← MODIFY: add specs for new methods
```

No new files — everything goes on the existing Engine class.

---

## Testing approach

**Key management and crypto:** Mock the `key_deriver` with an RSpec double that returns predictable keys. Test that the engine calls the right methods with the right parameters.

For crypto round-trip tests: use real SDK primitives — create a real PrivateKey, construct a real key_deriver, test encrypt→decrypt, sign→verify, hmac create→verify.

**Certificates:** Integration test against PostgreSQL (same setup as HLR #4). Test the full acquire→list→prove→relinquish lifecycle.

**Auth:** Simple — test with and without key_deriver.

**Network:** Test that `network` and `version` return configuration values. `height` and `header_for_height` are stubs for now.

---

## Verification

1. `bundle exec rspec` — all specs pass across both gems
2. All 28 BRC-100 methods implemented (no more NotImplementedError except height/header_for_height)
3. Crypto round-trip: encrypt→decrypt produces original plaintext
4. HMAC round-trip: create→verify succeeds, tampered data raises InvalidHmacError
5. Signature round-trip: create→verify succeeds, wrong data raises InvalidSignatureError
6. Certificate lifecycle: acquire→list→prove→relinquish
7. Auth: authenticated? returns true with key_deriver, false without
