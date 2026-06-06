# Plan — #270: Categorise Arcade `{error, reason}` broadcast rejection as terminal

**Branch:** `feat/270-rejection-shape-categorisation` off `feat/249-broadcast-network-boundary`
**Related:** #251 (where the gap was surfaced), #252 (EF reconstruction made the gap visible), #271 (path unification — fix lands in one place)

## Context

Arcade returns two distinct response shapes for failures:

- **Status-poll / SSE shape**: `{txStatus: "REJECTED", extraInfo: "...", ...}` — what `Engine::Broadcast#terminal_failure?` / `#terminal_status?` / `#categorize_terminal_reason` were written for. Works.
- **Synchronous broadcast HTTP 4xx shape**: `{error: "transaction failed validation", reason: "'PreviousTx' not supplied"}` — no `txStatus`, no `extraInfo`. Just a brief diagnostic body.

After `bsv-sdk-0.23.1`'s parse fix (sgbett/bsv-ruby-sdk#793), `response.data` carries the parsed body even on non-2xx. The wallet sees the fields. But `terminal_failure?` only checks `response.data['txStatus']` — nil for the broadcast-rejection shape — so it returns false, `submit` drops into the else branch, and the event lands as `task.failed reason=:unknown` instead of `task.aborted reason=:policy_violation`. The action is *not* reject_action'd from the synchronous path; SSE catches it via the parallel channel (already correct), but the two paths disagree.

With #271 merged, both inline and daemon broadcast paths flow through `Engine::Broadcast#submit` → `terminal_failure?` → `categorize_reason`. Single decision surface. One fix in one place.

## Approach

1. **`#terminal_failure?`** also returns true when the response carries Arcade's broadcast-rejection shape (`{error, reason}` hash with the `error` key present).
2. **`#categorize_reason`** routes the broadcast-rejection shape to `:policy_violation` (matches the existing terminal `REJECTED` bucketing — both mean "the network refused this tx").
3. **`#handle_submit_terminal`**'s event emission preserves the `reason` string so the diagnostic isn't lost on triage.

The status-poll shape stays the primary discriminator (still checked first); the broadcast-rejection check is a fallback for the synchronous path. SSE EventApplicator is unchanged (already correct).

## Changes

### `lib/bsv/wallet/engine/broadcast.rb`

- **New predicate** `#arcade_broadcast_rejection?(response)`: true when `response.data` is a Hash with an `error` key (Arcade's synchronous broadcast-failure body shape).
- **`#terminal_failure?`**:
  ```ruby
  def terminal_failure?(response)
    return false unless response.data
    return true if terminal_status?(response.data['txStatus'], response.data['extraInfo'])
    arcade_broadcast_rejection?(response)
  end
  ```
- **`#categorize_reason`** — when status-poll bucketing yields `:unknown` AND the body carries the broadcast-rejection shape, bucket as `:policy_violation`:
  ```ruby
  def categorize_reason(response)
    return :malformed unless response.data

    tx_status = response.data['txStatus'].to_s.upcase
    return :stale_beef if tx_status == 'MINED_IN_STALE_BLOCK'

    reason = categorize_terminal_reason(response.data['txStatus'], response.data['extraInfo'])
    return :policy_violation if reason == :unknown && arcade_broadcast_rejection?(response)
    reason
  end
  ```
- **`#handle_submit_terminal`** — add `arc_reason: response.data['reason']` to the `task.aborted` event payload. Preserves the `'PreviousTx' not supplied` / similar diagnostics. Current `arc_status: response.data['txStatus']` stays.

### Specs (`spec/bsv/wallet/engine/broadcast_spec.rb`)

New context `"when 4xx with Arcade's broadcast-rejection shape (#270)"`:

- The response data is `{ 'error' => 'transaction failed validation', 'reason' => "'PreviousTx' not supplied" }`, `http_success?` false, `code` 400.
- `submit` calls `handle_submit_terminal` → `@store.reject_action(action_id)`.
- Emits `task.aborted` with `reason: :policy_violation` and `arc_reason: "'PreviousTx' not supplied"`.
- Does **not** emit `task.failed reason: :malformed` (regression assertion for the gap this fix closes).

## What this changes behaviourally

- Synchronous broadcast 4xx responses with Arcade's `{error, reason}` body now trigger `reject_action` from the submit path. Action cascade happens at the moment of the synchronous response instead of waiting for the parallel SSE channel.
- `task.aborted` event payload gains `arc_reason:` (always present; nil for the status-poll shape). Strict additive change — existing event consumers ignore unknown keys.
- The categorisation `:unknown` bucket shrinks — Arcade's broadcast-rejection shape now buckets as `:policy_violation`.

## What stays unchanged

- Status-poll / SSE path's existing categorisation (still primary).
- `ArcStatus::REJECTED` set.
- 503 / backpressure dispatch.
- Wire format.

## Implementation order

1. Add `#arcade_broadcast_rejection?`, extend `#terminal_failure?` and `#categorize_reason`.
2. Add `arc_reason:` to the `task.aborted` event.
3. Add the new spec context.
4. Run unit suite + rubocop.
5. Single commit: `fix(broadcast): categorise Arcade {error, reason} 4xx as terminal (#270)`.

## Risks

- **Other ARC implementations** might return non-Arcade 4xx bodies with an `error` key meaning something else. The `arcade_broadcast_rejection?` predicate is permissive ("has `error` key"). If a non-rejection HTTP 4xx ever uses the same shape, we'd false-positive-cascade. Mitigation: tighten the predicate to require BOTH `error` AND `reason` (Arcade's actual contract). Fewer false positives, same true-positive coverage. Use this tighter form.
- **Out-of-scope rejections still bucket as `:unknown`** — if Arcade later adds a third shape, neither check catches it and the action stays alive for the SSE channel. Acceptable fallback; we're just plugging the known gap.

## Out of scope

- Changes to Arcade's response shape (upstream concern; sgbett/bsv-ruby-sdk territory).
- Reworking `ArcStatus::REJECTED` membership.
- SSE EventApplicator (unchanged — already handles correctly).
