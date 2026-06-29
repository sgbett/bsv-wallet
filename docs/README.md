# BSV Wallet — Documentation

This directory contains the documentation source for the BSV Wallet gem, built with
[Jekyll](https://jekyllrb.com/) and the [just-the-docs](https://just-the-docs.com/) theme.

## Local development

The docs Rake tasks live in `gem/bsv-wallet/Rakefile`. Run them from the gem
directory:

```bash
cd gem/bsv-wallet
bundle exec rake docs:serve
```

The site is served at `http://localhost:4000/bsv-wallet/` with live-reload enabled.

### Testing redirect stubs locally

`jekyll-redirect-from` prepends `site.url + site.baseurl` to redirect targets,
so by default a local preview redirects you to the production GitHub Pages URL
(`https://sgbett.github.io/bsv-wallet/...`). To verify a redirect resolves
within localhost, override both at serve time:

```bash
cd docs && bundle exec jekyll serve --livereload \
  --url 'http://localhost:4000' --baseurl ''
```

Then load the old path (e.g. `http://localhost:4000/design/`) and confirm it
redirects to the new path on the same host.

To build without serving:

```bash
cd gem/bsv-wallet && bundle exec rake docs:build
```

To lint frontmatter across all hand-authored `.md` files:

```bash
cd gem/bsv-wallet && bundle exec rake docs:lint
```

To check internal links and anchors in the built site (offline):

```bash
cd gem/bsv-wallet && bundle exec rake docs:proofread
```

To regenerate the YARD API reference into `docs/reference/api/`:

```bash
cd gem/bsv-wallet && bundle exec rake docs:generate
```

## Why `docs/Gemfile.lock` is committed

The wallet gem itself does **not** commit `Gemfile.lock` — standard practice for
libraries, where consumers resolve their own dependency tree.

The docs site is different: it is a **deployable application** (GitHub Pages).
Committing the lockfile ensures:

- CI produces byte-for-byte identical output to local development.
- A stale or yanked upstream release cannot silently break the deployed site.
- Dependabot diffs are explicit and reviewable.

## Plugin set

The site uses built-in just-the-docs features plus two Jekyll plugins:

- **`jekyll-redirect-from`** — emits HTML redirect stubs for moved pages
  (driven by the `redirect_to:` frontmatter key). Whitelisted on GitHub Pages.
- **`jekyll-relative-links`** — rewrites relative `[text](path.md)` links to
  their permalink form at build time. MkDocs did this transparently; Jekyll
  doesn't by default, so without this every internal `.md` link breaks in the
  rendered HTML.

There are no files under `_plugins/`, which keeps the build compatible with
GitHub Pages safe mode if ever needed.

## File structure

```
docs/
  _config.yml              — Jekyll + just-the-docs configuration
  _sass/color_schemes/     — bsv-ruby brand palette (SCSS)
  index.md                 — Home page (nav_order: 1)
  about-these-docs.md      — Doc-system orientation
  getting-started/         — Installation, quickstart
  guides/                  — How-to guides
  concepts/                — Architecture, lifecycle, transmission, etc.
  reference/               — Canonical reference
    api/                   — YARD output (auto-generated, git-ignored)
    drafts/                — Outbound BRC drafts (nav-excluded)
    external/              — Vendored upstream specs (e.g. BRC-100)
  Gemfile                  — Jekyll gem dependencies
  Gemfile.lock             — Committed (deployable application policy)
```
