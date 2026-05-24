# BSV Wallet

A Ruby implementation of the [BRC-100](https://github.com/bitcoin-sv/BRCs/blob/master/wallet/0100.md) BSV wallet interface — transaction management, key derivation, encryption, certificates, and identity verification.

## Overview

This is a Ruby wallet, not a Ruby port of a TypeScript wallet. The BRC-100 specification defines the external contract; the implementation is idiomatic Ruby throughout.

**Gem:** `bsv-wallet` — core wallet implementing the BRC-100 interface, supporting both SQLite and PostgreSQL backends.

## Key Design Principles

- **Binary internally** — all binary data stays binary throughout the wallet internals. Hex conversion happens only at external API boundaries where a specification explicitly requires it.
- **Synchronous interface** — all interface methods are synchronous and return hashes. Async behavior is an infrastructure concern handled by a wrapping service layer.
- **American English** — matching the BRC-100 spec: `internalize_action`, `randomize_outputs`, and so on throughout.
- **Ruby idioms** — keyword arguments, guard clauses, symbols for enumerations, YARD for documentation.

## Getting Started

```ruby
# Gemfile
gem 'bsv-wallet'
gem 'pg'  # only if using PostgreSQL (defaults to SQLite)
```

## Documentation

- [Design](design.md) — architecture, philosophy, and implementation details
- [Wallet daemon events](wallet-events.md) — structured lifecycle events for walletd background tasks
