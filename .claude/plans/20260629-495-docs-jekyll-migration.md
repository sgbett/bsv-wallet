# Docs migration: MkDocs → Jekyll + `just-the-docs` (bsv-wallet)

Date: 2026-06-29
HLR: #495
Status: Draft — lean path, single PR

## Why

Upstream MkDocs is abandoned (last release Aug 2024) and a "MkDocs 2.0"
rewrite has been announced that intentionally breaks every existing theme,
plugin, and configuration. The current `docs.yml` already sets
`DISABLE_MKDOCS_2_WARNING: true` to suppress the noise — a workaround, not
a fix. `mkdocs-material` is bifurcating (squidfunk → Zensical; plugin
ecosystem → ProperDocs). Picking either ties us to ongoing Python-side
instability.

Migrating to Jekyll + `just-the-docs` removes the time-bomb exposure in
one move, drops Python from CI, and aligns the docs toolchain with the
project's Ruby identity.

## Verified template

This is a **direct transplant** of the migration done on `sgbett/bsv-ruby-sdk`
via #861 / PR #865 plus follow-ups #869–#875. The template and its
post-merge fixes are codified in the artefacts being carried over:

- `_config.yml` `defaults:` block restoring `layout: default` alongside
  the `reference/api` nav/search exclusion (the gotcha that produced an
  unstyled deployed site)
- `permalink: pretty` preserving MkDocs trailing-slash URL shape
- Exact-pinned `just-the-docs`, `jekyll-redirect-from`, Mermaid version
  (supply-chain hygiene)
- `jekyll-relative-links` so internal `[text](path.md)` links resolve
- `html-proofer` not lychee (baseurl-aware via `--swap-urls`)
- YARD index generator emits its own frontmatter (idempotent regeneration)
- `docs:lint` excludes `_site/`, `vendor/`, `.bundle/`; strict prefix
  matching with trailing `/`
- `.rubocop.yml` `AllCops.Exclude` restores defaults alongside
  `docs/**` exclusion
- Unified Ruby 3.4 across both `setup-ruby` steps
- Build job has `pages: write` + `id-token: write` (required by
  `configure-pages`)
- Workflow `paths:` includes root `Gemfile`
- `pull_request:` dry-run trigger; `deploy` gated to `push` on `master`

## Execution shape — lean path, brief explainer

The do-hlr skill's lean off-ramp fits because the migration has been done
once with a verified template, ten specialists already weighed in for that
round, and every concrete finding is now baked into the artefacts being
carried over. Re-running specialist co-production would re-derive the same
recommendations from the same plan. No specialist phase, no sub-issuing,
no formal review — single PR, three migration commits driven by the
template, PR dry-run catches drift before merge.

## Workstreams (3 commits + plan)

1. **Plan** — this file.
2. **Jekyll foundation + palette** — `docs/Gemfile`, `docs/Gemfile.lock`
   (committed; deployable app policy), `docs/_config.yml`,
   `docs/.gitignore`, `docs/_sass/color_schemes/bsv-ruby.scss` (verbatim
   from bsv-ruby-sdk), `docs/README.md` (local-preview docs incl.
   `--url`/`--baseurl` override), Rakefile additions (`docs:serve`,
   `docs:build`, `docs:lint`, `docs:proofread`), `.rubocop.yml` exclusion.
3. **Content migration** — per-file nav frontmatter on 36 hand-authored
   `.md` files (preserving Home, About these docs, Getting Started,
   Guides, Concepts, Reference structure); rewrite 6 admonitions to
   just-the-docs callout syntax; create 3 redirect stubs honouring
   `mkdocs.yml`'s `redirect_maps`; verify internal links.
4. **CI rewrite + decommission** — replace `.github/workflows/docs.yml`
   with the Jekyll + Pages-Actions chain; add `/docs` bundler entry to
   `.github/dependabot.yml`; delete `mkdocs.yml`, `docs/requirements.txt`;
   update `README.md`/`CONTRIBUTING.md` to reference `bundle exec rake
   docs:serve` / `rake docs:build`.

## Admonitions to rewrite (from grep)

- `docs/getting-started/quickstart.md:120` — `!!! warning "Gotchas to know about"`
- `docs/getting-started/installation.md:26` — `!!! warning "Postgres needs \`pg\` in your own bundle"`
- `docs/guides/sending-payments.md:7` — `!!! warning "\`no_send\` defaults to \`false\`"`
- `docs/concepts/transactions-and-beef.md:31` — `!!! note "Fail-closed by construction"`
- `docs/reference/api/index.md:5` — `!!! info "Generated content"`
- `docs/reference/external/BRC100.md:1` — `!!! info "Vendored upstream"`

## Redirects (from `mkdocs.yml`)

- `design.md` → `concepts/architecture.md`
- `wallet-events.md` → `reference/events.md`
- `reference/createaction-lifecycle.md` → `concepts/action-lifecycle.md`

## Out of scope

- bsv-wallet-specific social preview / palette divergence (carry
  `bsv-ruby.scss` as-is; revisit when wallet has its own social preview)
- Section renaming
- Content rewrites
- Real per-PR preview deploys (Level 2 from the bsv-ruby-sdk discussion;
  Level 1 dry-run is sufficient)

## Pre-merge admin checklist

- [ ] Tag current `gh-pages` HEAD as `gh-pages-mkdocs-final` for rollback
- [ ] Flip Settings → Pages source to "GitHub Actions" before merge

## Acceptance criteria

Covered in HLR #495.
