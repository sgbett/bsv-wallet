# Security policy

The `bsv-wallet` and `bsv-wallet-postgres` gems are published from this repository.

## Reporting a vulnerability

Please report security issues via GitHub's private vulnerability
reporting:

- Go to the [Security tab](https://github.com/sgbett/bsv-wallet/security)
- Click **Report a vulnerability**

This opens a private draft advisory that only maintainers can see.
Please do **not** open a public issue or PR for anything security-relevant.

If you cannot use GitHub's reporting flow, email simon@bettison.org
with "bsv-wallet security" in the subject line. I will acknowledge
within a few working days.

## Supported versions

This project is pre-1.0 and moves quickly. Only the **latest released
version of each gem** receives security fixes. If you are pinned to an
older version, please upgrade before reporting — the fix for most
issues is "use the current release".

| Gem                  | Latest                                                                                | Receives security fixes |
| -------------------- | ------------------------------------------------------------------------------------- | ----------------------- |
| `bsv-wallet`         | see [rubygems.org/gems/bsv-wallet](https://rubygems.org/gems/bsv-wallet)             | yes                     |
| `bsv-wallet-postgres`| see [rubygems.org/gems/bsv-wallet-postgres](https://rubygems.org/gems/bsv-wallet-postgres) | yes                |

## What to expect

- Acknowledgment of your report within a few working days
- An initial assessment — accepted, needs more information, or out of
  scope — shortly after
- For accepted reports, a coordinated disclosure: we will keep the
  issue embargoed while developing and testing a fix, file a GitHub
  Security Advisory with a CVE ID, and publish the advisory at the
  same time as the patched gems reach RubyGems
- Credit in the published advisory if you would like it (or anonymous
  if you prefer)

## Scope

In scope:

- UTXO lifecycle integrity (double-spend prevention, input locking
  atomicity, premature output promotion)
- Transaction ID handling (byte-order confusion leading to silent
  lookup failures or wrong proof linkage)
- Input resolution correctness (wrong source outpoint, wrong key
  derivation parameters leading to unspendable funds)
- BEEF/SPV validation bypass (accepting invalid merkle proofs,
  skipping fee adequacy checks)
- Broadcast lifecycle (unsigned transaction submission, callback
  handling that silently drops mined status)
- Proof management (linking proofs to wrong transactions, accepting
  malformed merkle paths)
- Database atomicity failures that leave partial state recoverable
  only by manual intervention

Out of scope:

- Cryptographic correctness in signing, key derivation, or encryption
  — those belong in the [bsv-ruby-sdk](https://github.com/sgbett/bsv-ruby-sdk)
- DoS via resource exhaustion unless a realistic attack path exists
- Issues requiring a compromised local environment (stolen keys,
  malicious dependencies, hostile developer tooling)
- Weaknesses in the BSV protocol itself — those belong upstream
- PostgreSQL misconfiguration or network-level attacks on the database

## Past advisories

Published advisories are tracked in [`.security/advisories/`](.security/advisories/)
and on the [GitHub Security Advisories tab](https://github.com/sgbett/bsv-wallet/security/advisories).
