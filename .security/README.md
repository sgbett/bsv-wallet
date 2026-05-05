# Security

This directory holds security-related artefacts for the gems published from this repository (`bsv-wallet` and `bsv-wallet-postgres`):

- `advisories/` — draft and published security advisories. Each file corresponds to a GitHub Security Advisory (GHSA) and, where assigned, a CVE ID. Drafts live here before publication and are updated in-place when the advisory is published.

Security reports should be made via GitHub's private vulnerability reporting (Security tab → Report a vulnerability) rather than public issues.

## Advisory lifecycle

1. Draft the advisory as a Markdown file in `advisories/` using the existing files as a template.
2. File a GitHub Security Advisory (Security → Advisories → New draft) and request a CVE ID.
3. Keep the draft private until the patched release is tagged and pushed to RubyGems.
4. Publish the GHSA on release day.
5. Update the Markdown file with the final GHSA ID, CVE ID, and publication date.

## Index

| GHSA | Finding | Packages | Severity | Status |
| --- | --- | --- | --- | --- |
| — | — | — | — | No advisories yet |
