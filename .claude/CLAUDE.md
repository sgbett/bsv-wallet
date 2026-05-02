# BSV Wallet — Project Instructions

## Language Convention: American English

**Override global preference:** This project uses **American English** throughout — code, comments, documentation, and commit messages.

The BRC-100 specification defines method names using American English (`internalizeAction`, `randomizeOutputs`). Using British English for Ruby method names (`internalise_action`, `randomise_outputs`) while the spec uses American creates confusion about which convention applies where. Consistency wins: American English everywhere.

Examples: behavior, color, organization, optimize, summarize, favor, center, internalize, randomize.

## Transaction ID Convention: wtxid / dtxid

The wallet stores and operates on **wire-order** transaction IDs throughout. No byte-order conversions in the data path.

### Naming rules

| Name | Byte order | Format | Usage |
|------|-----------|--------|-------|
| `wtxid` | Wire (raw SHA256d) | Binary | Internal: storage, computation, method params, variables |
| `dtxid` | Display (reversed) | Hex string | External: ARC API calls, logs, CLI output, human display |
| `txid` | Spec-defined | Varies | BRC-100 spec names only (`known_txids:`, return key `:txid`) |

### Rules

- **Internal code**: always `wtxid`. Variables, method parameters, hash keys, database columns.
- **BRC-100 spec names**: keep as-is (`known_txids:`, `:txid` return key). Add a boundary comment explaining the convention crossing. Values are wire-order wtxids.
- **External API calls** (ARC, WhatsOnChain): use `dtxid` — display-order hex. The `DisplayTxid` module provides this on Sequel models.
- **SDK API names** (e.g., `PathElement#txid` boolean flag, `txOrId` in TSC): leave as-is, these are third-party conventions.
- **New APIs we control**: prefer wtxid, include `txid_format: 'wire'` in responses where not prohibited by spec.

### Source

`Transaction#wtxid` returns wire order (SDK v0.17.0+). `Transaction#txid` returns display order — a convenience method for humans, never used in the data path.
