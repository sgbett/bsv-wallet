# The action lifecycle

In BRC-100 an **action** is a transaction together with the wallet's intentions for it. It is the central object the wallet manages, and the way this gem models its lifecycle is one of its defining characteristics: an action moves through a sequence of phases, and its *status* is read back out of the database structure rather than stored.

This page explains the phases, the three broadcast intents that branch them, how speculative promotion works, and what happens when an optimistically-promoted action is contradicted. It is the operational narrative; the canonical state machine — atomic Store units, per-flow gap/owner audit, recovery mechanisms — lives in [Action lifecycle (reference)](../reference/action-lifecycle.md). When the two pages disagree, the reference wins.

## The phases

`build_action` (the Engine primitive that `BRC100#create_action` resolves to) drives a transaction through a numbered sequence — the phases are the code's own labels, surfaced through the `Engine::Action` lifecycle object (`build_via_funding!`, `sign_and_save!`, `complete_internal!`):

1. **Phase 1 — lock.** The initial input set is resolved and the action row is created. Chosen inputs are *locked* structurally: a row in the `inputs` table claims each output. Because that table has a `UNIQUE` constraint on `output_id`, two concurrent actions cannot lock the same UTXO — the second insert simply fails. The lock *is* the claim; there is no "reserved" flag to leak on a crash.

2. **Phase 2 — fund.** The *funding loop* runs in `Engine::FundingStrategy`. It templates the transaction through `Engine::TxBuilder`, computes the exact fee at the configured rate, and reports any shortfall; the loop tops up by selecting and locking further inputs until the transaction balances. Change outputs are written here but are **not yet canonical** — no `promotions` row exists.

3. **Phase 3 / 4 — broadcast and promote.** What happens next depends entirely on the action's **broadcast intent** (below). Either way, Phase 4 is the moment a `promotions` row is written, declaring the outputs canonical.

Signing produces the `wtxid` and the raw transaction bytes; until that happens the action's `wtxid` is `NULL` and it is considered `:unsigned`.

## The three broadcast intents

Every action carries a `broadcast_intent`, chosen by `map_broadcast_intent` from two flags passed in by `BRC100#create_action`:

```ruby
def map_broadcast_intent(no_send, accept_delayed_broadcast)
  if no_send then :none
  elsif accept_delayed_broadcast then :delayed
  else :inline
  end
end
```

| Intent | Triggered by | What happens | Phase 4 timing |
|--------|--------------|--------------|----------------|
| **`:none`** (internal) | `no_send: true` | The transaction is never sent to ARC. It produces canonical wallet state directly — used by incoming BEEF, imported UTXOs, WBIKD locks, and the `send_payment` porcelain. | **Synchronous**, inside `build_action`. |
| **`:delayed`** | `no_send: false`, `accept_delayed_broadcast: true` (the default send path) | The action is queued. The daemon discovers it (`broadcast_at IS NULL`), broadcasts it via `Network::Broadcaster`, and later resolves its status. | Deferred, on broadcast acceptance. |
| **`:inline`** | `no_send: false`, `accept_delayed_broadcast: false` | The transaction is broadcast synchronously within the call (the same `Engine::Broadcast` worker, reached via the REP socket), then promoted. | Synchronous, after the broadcast returns. |

The distinction between **internal** (`:none`) and **broadcast** (`:delayed` / `:inline`) actions runs deep. Internal actions are wallet truth by design — there is no network to disagree with them — and the database physically forbids rejecting or deleting them once promoted. Broadcast actions are *provisional* until the network confirms them, which is where speculative promotion comes in.

## Speculative promotion

For the send path, the wallet does not wait for the network before letting the user move on. Outputs are persisted at sign time with no promotions row, and Phase 4 inserts the row **once the broadcast is accepted** (any non-rejected ARC status counts as acceptance). The change created by a delayed send becomes spendable speculatively, so a sequence of payments can be chained without round-tripping to a miner between each.

The promotions row is therefore the structural pivot of the whole send lifecycle:

- *no promotions row* — output exists, transaction signed, network has not yet accepted it.
- *promotions row exists* — network accepted (or the action was internal); the output is canonical UTXO state.

This row is gated by foreign key to the broadcast that authorised it (`promotions_broadcast_status_fkey`): a flip to `REJECTED` has to delete the promotions row before it can take effect, so the schema makes "promoted but actually rejected" structurally impossible. The gate is one half of the composite-FK pattern described in [Architecture: Designed for scale](architecture.md#designed-for-scale).

This optimism is what makes the wallet fast, but optimism needs an undo. That is the reject cascade.

## Deriving status

Because there is no status column, status is computed on demand by `Action#derived_status`. The canonical derivation table — predicate → status — lives in [Principle of state](../reference/principle-of-state.md), and the state-machine framing (atomic Store units, gaps, recovery owners) is in [Action lifecycle (reference)](../reference/action-lifecycle.md).

The ordering of the derivation encodes precedence: a proof beats everything (`:completed`), an internal action is never "sending", and acceptance (`:unproven`) is checked before rejection because a promotions row means the network already took the transaction.

## Unwinding: the reject cascade

When the daemon's resolution loop learns that a broadcast was *terminally rejected*, the speculative promotion has been contradicted and must be reversed. `reject_action` does this, and crucially it **cascades forward**: if the rejected action's change was already spent by a child action, that child's promotion was built on a now-invalid foundation and must be rejected too. The cascade walks `child_actions_of` recursively (tracking visited nodes to handle the diamond shapes that arise from, e.g., consolidations).

The cascade refuses to proceed in two situations, both of which mean "something is wrong that an unwind would make worse, not better":

- **`CannotRejectInternalActionError`** — a descendant has `broadcast_intent = 'none'`. Internal actions are wallet truth; encountering one mid-cascade means an upstream invariant was violated. The transaction rolls back, leaving the row alive for investigation rather than silently destroying canonical state.
- **`CannotRejectAcceptedActionError`** — a descendant's broadcast already reached an *accepted* status (`SEEN_ON_NETWORK`, `MINED`, …). Rejecting it would delete the wallet's record of an on-chain artefact and deepen a wallet-versus-chain divergence. The correct response is operator investigation, not an automatic unwind.

This is the throughput-versus-safety trade made explicit: the wallet is eager to promote, but the unwind path is conservative and fails loudly the moment an unwind would itself be unsafe.

## Deferred signing

`build_action` can return a *signable transaction* handle instead of a finished one, by separating creation from signing. The caller later completes it with `sign_action(spends:, reference:)`. This supports flows where signing authority is held elsewhere, or where inputs must be reviewed before committing.

Combining deferred signing with `no_send: true` is explicitly **not** implemented in the base wallet. The `noSend × sendWith` chained-send combination — building a chain of transactions locally and flushing the batch atomically — is deferred to **#192** (see [`.architecture/reviews/20260619_noSend-sendWith-design-notes.md`](../../.architecture/reviews/20260619_noSend-sendWith-design-notes.md) for the design notes). It requires a `batches` entity in the schema with constraints that enforce "a batch cannot partially succeed"; bringing it back without that structural backing would reintroduce the drift the strict 4-phase design was built to prevent.

## Receive alternatives

A wallet can receive a payment two ways:

- **Internalise a BEEF envelope** that arrived out-of-band (file, queue, pipe). `internalize_action` runs the full SPV verification before any output enters the wallet. See [Transactions & BEEF](transactions-and-beef.md).
- **Accept a transmission** from a peer that POSTed it directly. The HTTP layer is `Network::PeerDelivery`; the SSRF gate is `Network::EndpointPolicy`. See [Transmission](transmission.md).

Both paths produce an `:internal` action. The structural promise is the same: the moment the row is written, it is wallet truth.

## Related

- [Action lifecycle (reference)](../reference/action-lifecycle.md) — canonical atomic-units table, per-flow gap audit, recovery mechanisms.
- [Principle of state](../reference/principle-of-state.md) — why there's no status column, and the derivation table.
- [Transactions & BEEF](transactions-and-beef.md) — what gets shipped at Phase 3 (send path) and what arrives at internalize time (receive).
- [Transmission](transmission.md) — wallet-to-peer delivery of the same Atomic BEEF.
- [Persistence](persistence.md) — the `promotions` and `broadcasts` tables that gate Phase 4.
