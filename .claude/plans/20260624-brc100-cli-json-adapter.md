# Plan — BRC-100 CLI (`bin/brc100`) as the CLI transport of the #180 JSON adapter

**Filed as:** #431 (sub-issue of **#180**). Sibling: **#223** (HTTP transport).
**Status:** design captured — build deferred until #223's shared layer lands. No code in this pass.
**Scope:** the 28 BRC-100 methods, invoked as `brc100 [wallet_name] <method> ['<json>']` — the
*conformance* surface; `wallet` is reserved for the native surface (see "Surface naming" below).

---

## What this captures (and why it isn't a new mechanism)

A unified `brc100 <method> <json>` CLI is **not** a new design — it is the CLI transport of an
architecture already in flight. Reviewing the work landed since the session-start commit `6d5193e`
(~250 commits) showed the wallet already reserves space for exactly this.

**Engine movement.** The Engine was decomposed into single-responsibility collaborators behind
`interface/` ports — `Hydrator` (egress BEEF assembly + wtxid cache), `TxBuilder`, `FundingStrategy`,
`BeefImporter`, `Policy`, `Reaper`, `Transmission`, `InputSource`, `MerklePathNormaliser`,
`HydratedTxCache` (#296/#327/#359/#385). The 28 spec methods were sliced out as **Engine primitives**,
with `BSV::Wallet::BRC100` promoted module→class as the conformance wrap reached via `engine.brc100`
(#365→#400→#402→#405; ADR-026). `reference/*` relocated to **`docs/reference/*`**;
`seek_permission` dropped from primitives.

None of that closed the JSON conversion edge — confirmed: no BRC-100 *value* serializer (binary
`wtxid`/`atomic_beef` → JSON hex) in `gem/bsv-wallet/lib`, only the generic `CLI::Output.write_json`
writer (it JSON-encodes whatever hash it is handed, without converting values). `engine.brc100` still
emits binary (`txid: result[:wtxid]`, `tx: atomic_beef` — `brc100.rb:99–117`), and `bin/` scripts
still hand-roll hex (`bin/create_action:93`). But *how* that edge closes is no longer an open
question — it's specified by #180/#223.

---

## The architecture this belongs to (already recorded)

- **HLR #180 — "Multi-adapter BRC-100 API surfaces"** (OPEN). The umbrella. "The engine's
  flat-kwargs interface is the **internal contract**; each adapter is a **boundary**… Adapters own
  translation only." Named surfaces: a **JSON adapter** (parses JSON, unpacks BRC-100's nested
  `options` into flat kwargs, keeps `originator` distinct, rejects malformed/unknown shapes, exposes
  all 28 methods) and an **ABI** binary codec (HTTP-first, sockets later). OMQ/streaming future.
- **HLR #223 — "Expose Engine over BRC-103 HTTP"** (OPEN, *not yet built*). Builds the **shared
  machinery**: `BSV::Wallet::WireProcessor` (generic dispatcher over any `Interface::BRC100`, using
  the bsv-sdk per-call serializers/validators), a Rack `HTTPServer` (JSON variant
  `POST /v1/wallet/:method` via `BSV::WireFormat`; binary BRC-103 variant), **domain-error → `WERR_*`
  mapping at the boundary**, and the wiring of `getHeight`/`getHeaderForHeight` through `ChainTracker`.
- **`docs/reference/core-vs-conformance.md`** (load-bearing principle) + **`brc100-conformance.md`**
  (living per-method register). The register is the authority on "where it makes sense": 26/28 core;
  the 2 chain stubs wired by #223; `noSend`/`sendWith` Deferred (#192); `originator`/`seekPermission`
  Boundary-only; reserved-name rejection tracked by #428.

**The conclusion:** `brc100 <method> <json>` is the CLI transport of #180's JSON adapter — the same
`{JSON adapter + WireProcessor}` path #223 exposes over Rack, bound to argv/stdin/stdout. The
"conversion edge" is that shared layer; the binary-`wtxid` vs display-`dtxid` mismatch is a **#223
concern to settle once**, not a CLI shim. The wallet writes no serialization for the CLI.

---

## The design (the genuinely CLI-specific part)

A `bin/brc100` executable that is **transport only** — everything BRC-100 is delegated:

- **Grammar:** `brc100 [wallet_name] <method> ['<json>']`; JSON from the positional **or** stdin
  (stdin mandatory for large `internalizeAction` BEEF — `ARG_MAX`). Method token in BRC-100 camelCase
  (`createAction`), snake tolerated.
- **Wiring:** boot via `CLI.boot` / `CLI.extract_wallet_name` (`cli.rb`); feed parsed JSON +
  `--originator` to the shared JSON adapter / `WireProcessor` over `engine.brc100`; print via
  `CLI::Output.write_json` (TTY-aware). Malformed-shape rejection and 28-method dispatch come from the
  adapter, not the CLI.
- **Errors/exit codes:** map the adapter's `WERR_*` to JSON-on-stderr + non-zero exit;
  unsupported/deferred methods surface their real `WERR_*` honestly (no curation).
- **Method stances:** defer to `docs/reference/brc100-conformance.md`, not an allow-list.
- **Blast radius:** replaces the BRC-100 *plumbing* bins (`create_action`, `list_outputs`,
  `internalize`) and adds the rest of the 28. Porcelain (`create`, `balance`, `import`, `receive`),
  operational (`sweep`, `consolidate`, `derive`, `lock`, `select_utxos`, `transmit`) and `walletd`
  are untouched.

---

## Surface naming & the native/conformance split

Both flow from `docs/reference/core-vs-conformance.md` (core wallet ≠ BRC-100 conformance):

- **`bin/brc100`, not `bin/wallet`.** This is the BRC-100 *conformance* branch specifically —
  camelCase spec methods, `WERR_*` codes, spec quirks. `bin/brc100` makes the contract identity
  explicit and **reserves `wallet` as the category for the native, wallet-vocab surface.** This
  consciously revises the original "one `wallet`" framing: `brc100` = conformance, `wallet`/native =
  core.
- **Native porcelain rebuild is a separate sibling effort.** Today's porcelain routes *through*
  BRC-100, so leaving it untouched keeps it bound to the spec's quirks the surface split exists to
  escape. Rebuilding it as wallet-vocab calling Engine primitives directly is the core-surface
  counterpart — its own HLR, not this sub-issue. (Not raised in this pass, by request.)

---

## Why a #180 sub-issue, not a new ADR

The decision already lives in #180 (multi-adapter boundary), #223 (shared WireProcessor + JSON
variant + error mapping), ADR-026 (primitives vs conformance wrap), `core-vs-conformance.md`. A fresh
ADR would restate them and risk ADR-staleness (ADRs are point-in-time; the conformance register is
the living home for per-method movement). Captured as #431, a sub-issue under #180.

---

## Dependencies & sequencing

1. **bsv-ruby-sdk #761** — BRC-103 wire layer (`WireFormat`, `Wire::Calls`, `WalletWireProcessor`).
2. **#223** — `BSV::Wallet::WireProcessor` + JSON adapter + `WERR_*` mapping + `getHeight` wiring.
   The CLI builds on this; it also settles the `wtxid`↔`dtxid` boundary for all adapters.
3. **#431 (this)** — `bin/brc100` transport on top. Could land alongside #223's `HTTPServer` (same
   shared layer, two transports) to prove the multi-adapter claim with two surfaces.

---

## Verification (for the eventual build)

- Reuse #180's acceptance gate (JSON adapter passes the conformance suite, exposes all 28); the CLI
  inherits both. Add a round-trip smoke test (`brc100 getNetwork`, `brc100 getVersion`, a
  `createAction` via stdin) asserting BRC-100-compliant JSON out.
- Confirm `--originator` stays distinct from `args` end-to-end (#180 invariant).
- Confirm `WERR_*` → exit-code mapping for a deferred/unsupported method.

---

## Out of scope

- ABI/binary and OMQ-streaming transports (#180 future; scaling-vision endgame).
- Native porcelain rebuild (separate HLR, not raised this pass).
- `noSend`/`sendWith` batching (#192), reserved-name enforcement (#428) — adapter-layer concerns.

---

## Status / next

Design captured here and in #431. **No implementation until #223's shared layer lands.** When it
does, build `bin/brc100` as a transport-only binding and close out #431.
