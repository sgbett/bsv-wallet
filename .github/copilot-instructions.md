# Copilot Code Review Instructions

## Purpose

This file has one job: make Copilot an effective reviewer of **every pull request** in this repository. Copilot is used here *only* for automated PR review — not implementation, not chat. (For the general role of this file, see GitHub's [custom instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions).)

It is **not** the source of truth for how the codebase works. It tells you *how* to review and *where* the truth lives. Don't restate architecture or conventions here — read them from the canonical sources below, so this file can't drift out of sync with them.

## How to review

bsv-wallet is a Ruby BRC-100 wallet: it manages UTXO lifecycle, transaction construction, broadcast, and proof management, delegating all cryptography to the `bsv-ruby-sdk` gem. It manages **real funds** — lead every review with **funds-at-risk and data-integrity impact**, not style.

Measure each PR against the project's own stated truth, in this order:

1. **Anchor on [`.architecture/principles.md`](../.architecture/principles.md).** Read the principles there — they are the yardstick the codebase is built on — and judge the change against them. (Don't rely on a copy here; this file deliberately doesn't restate them.)
2. **Consult the [`reference/`](../reference) doc that covers the subsystem the PR touches** — read the relevant one rather than guessing:
   - [`principle-of-state.md`](../reference/principle-of-state.md) — state is *read*, not stored (no status columns; derived status).
   - [`state-representations.md`](../reference/state-representations.md) — the per-element A–F conformance register (e.g. promotion is a `promotions` *row*, not an `outputs.promoted` flag).
   - [`state-boundaries.md`](../reference/state-boundaries.md) — stateless SDK / stateful wallet.
   - [`createaction-lifecycle.md`](../reference/createaction-lifecycle.md) — the action state machine: the 4-phase send path, the internal path, and the per-transition validation matrix.
   - [`schema-intent.md`](../reference/schema-intent.md) — why the schema is shaped the way it is (table split, Postgres-native types, the consolidated migration set).
   - [`raw-tx.md`](../reference/raw-tx.md), [`send_or_nosend.md`](../reference/send_or_nosend.md), [`transactions.md`](../reference/transactions.md) — wire format, no-send/batching, transaction handling.
3. **Conventions live in [`CLAUDE.md`](../CLAUDE.md)** — language (American identifiers / author's-voice prose), the `wtxid`/`dtxid` binary-vs-display byte-order discipline, `Transaction::Tx`-in-prose, and the identity-hex / derived-binary public-key rule. Flag violations against CLAUDE.md; don't restate its rules here.

## Flag inconsistencies — don't presume the code is right

When code contradicts a principle or a reference doc, that contradiction **is the finding**. Flag it and pose the load-bearing question: **is the code wrong, or is the principle/doc wrong?** Neither is assumed correct — surface it so a human resolves it deliberately rather than silently bending one to the other. The same applies when code disagrees with a `reference/` doc, or when two docs disagree.

## Self-check this file

When a PR changes `gem/bsv-wallet/lib/`, `reference/`, `.architecture/`, or `CLAUDE.md`, also check whether *these instructions* have gone stale: a class or method named here no longer exists, a canonical doc or convention file this links to was renamed or moved, or a load-bearing concept changed (the migration set, the promotion mechanism, a lifecycle phase, the layer split). If so, flag it — keep this file honest as part of normal review, not via a separate audit.

## What NOT to flag (avoid these false positives)

- **`txid:` in BRC-100 return hashes / `known_txids:` param** — spec-mandated key names; the values are wire-order `wtxid`. Correct.
- **ARC payload `txid` field / `action.dtxid` for ARC calls** — ARC's contract is display-order hex. Correct.
- **`PathElement.new(txid: true)`** — SDK boolean flag, not a naming violation.
- **No ActiveRecord** — this project uses Sequel deliberately. Don't suggest AR patterns.
- **American identifiers** (`internalize`, `randomize`, `behavior`) — match BRC-100 spec names; see CLAUDE.md's language convention. Not British-spelling bugs.
- **No `status` column / no `outputs.promoted` flag** — status is derived from structure by design (`principle-of-state.md`, `state-representations.md`); promotion is a `promotions` row.
- **Logical models in the `Engine` namespace** (`Engine::Broadcast`, `Engine::TxProof`) — behaviour-bearing models that intentionally aren't Store-level. Not a misplacement.
- **`Gemfile.lock` not committed** — standard for a gem.
- **`Set` used without `require 'set'`** — `Set` is an autoloaded core constant on Ruby ≥3.2 (the gem floors at 3.3). Established convention, not a missing dependency. (Same for other stdlib Ruby ≥3.2 autoloads.)

## Review output style

- Cite file paths and line numbers.
- Lead with funds / data-integrity impact; put style concerns last, or omit them.
- Give a concrete fix (code), not just a problem statement.
- Review the diff, not the whole codebase — pre-existing patterns aren't new findings.
