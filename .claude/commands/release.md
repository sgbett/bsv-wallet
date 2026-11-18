# Release a Gem

Guided release workflow for a single gem from this repo. Releases one gem per invocation, in two runs: the first opens the release PR, the second, once that PR is merged, tags and publishes. The default branch takes changes only by PR (2026-11-18, sgbett/dotfiles-claude#30), so the version bump lands by PR and the tag alone is pushed direct.

**Gem key:** `$ARGUMENTS`

---

## Gem Registry

| Key | Gem name | Version file | Tag prefix | Gemspec path |
|-----|----------|-------------|------------|--------------|
| `wallet` | `bsv-wallet` | `gem/bsv-wallet/lib/bsv/wallet/version.rb` | `v` | `gem/bsv-wallet/bsv-wallet.gemspec` |

Version constants:
- `wallet` → `BSV::Wallet::VERSION`

---

## Step 0: Hard Refusal

If `$ARGUMENTS` contains a space or comma (multiple keys), **stop immediately**:

> This skill releases one gem at a time. You provided multiple gem keys: `$ARGUMENTS`.
> Run `/release <key>` once per gem, in dependency order if releasing multiple gems.

Do not proceed past this step if multiple keys are detected.

---

## Step 1: Select Gem

If `$ARGUMENTS` is empty or not `wallet`, prompt:

```
Which gem do you want to release?

  wallet    bsv-wallet            currently 0.x.x

Enter: wallet
```

Read current version by running:
```bash
grep "VERSION = " gem/bsv-wallet/lib/bsv/wallet/version.rb
```

Once a valid gem key is confirmed, set these variables (conceptually) for the rest of the steps:
- `GEM_KEY` — the key (e.g. `wallet`)
- `GEM_NAME` — the gem name (e.g. `bsv-wallet`)
- `GEM_DIR` — the gem subdirectory (e.g. `gem/bsv-wallet`)
- `VERSION_FILE` — path to version.rb
- `TAG_PREFIX` — the tag prefix
- `GEMSPEC_PATH` — path to the gemspec
- `CURRENT_VERSION` — the version string extracted from version.rb

---

## Step 2: Pre-flight Checks

Run all four checks. Abort on any failure. Both parts start from a clean, current `master`.

**Check 1 — gh CLI authenticated:**
```bash
gh auth status
```
Abort if not authenticated:
> Pre-flight failed: `gh` CLI is not authenticated. Run `gh auth login` and retry.

**Check 2 — Clean working tree:**
```bash
git status --porcelain
```
Abort if any output:
> Pre-flight failed: working tree is dirty. Commit or stash your changes before releasing.
>
> Recovery: no changes have been made. Clean the tree and run `/release $GEM_KEY` again.

**Check 3 — On master branch:**
```bash
git branch --show-current
```
Abort if not `master`:
> Pre-flight failed: you are on branch `<branch>`, not `master`. Switch to master before releasing.
>
> Recovery: no changes have been made. Run `git checkout master` and retry.

**Check 4 — Local master up to date with origin:**
```bash
git fetch origin master
git status -uno
```
Abort if behind:
> Pre-flight failed: local master is behind origin/master. Run `git pull` before releasing.
>
> Recovery: no changes have been made. Run `git pull` and retry.

Display: "Pre-flight checks passed."

---

## Step 2b: spv_headers Checkpoint Freshness (advisory — #335)

The opt-in `:spv_headers` trust model validates from a hard-coded mainnet
checkpoint (`MAINNET_HEIGHT` in `gem/bsv-wallet/lib/bsv/network/checkpoints.rb`).
It should be refreshed toward the tip periodically — a stale checkpoint only
makes a fresh wallet's *first* `:spv_headers` verification slower (the cold
header-sync runs from the checkpoint up to the proof height, bounded by
`MAX_SYNC_SPAN`). This is **advisory**: staleness degrades first-sync latency,
it does not break anything — never abort the release on it.

```bash
CHECKPOINT=$(grep -oE 'MAINNET_HEIGHT\s*=\s*[0-9_]+' gem/bsv-wallet/lib/bsv/network/checkpoints.rb | grep -oE '[0-9_]+$' | tr -d '_')
TIP=$(curl -s --max-time 15 https://api.whatsonchain.com/v1/bsv/main/chain/info | grep -oE '"blocks":[0-9]+' | grep -oE '[0-9]+$')
echo "checkpoint=${CHECKPOINT:-unknown} tip=${TIP:-unavailable} gap=$(( ${TIP:-0} - ${CHECKPOINT:-0} ))"
```

If the gap exceeds ~25,000 blocks (≈ half a year), recommend refreshing before
tagging:

> Advisory: the `:spv_headers` mainnet checkpoint (height `$CHECKPOINT`) is
> ~`$GAP` blocks behind the tip. Consider refreshing it: fetch a recent,
> safely-final block's header fields (WhatsOnChain `/block/height/<h>`), update
> `MAINNET_HEIGHT` + `MAINNET_HEADER_FIELDS` in `checkpoints.rb` (the self-verify
> in `checkpoints_spec.rb` confirms the new anchor), and re-run `spec/bsv/network`.
> See `docs/reference/spv-header-verification.md`. Not a blocker — continue.

If the tip lookup fails (offline / rate-limited), note it and continue.

---

## Step 3: Which Part

The tag for the version on master says where the release stands:

```bash
git tag | grep "^${TAG_PREFIX}${CURRENT_VERSION}$"
```

- **Tag exists:** `$CURRENT_VERSION` is released. Continue with **Part 1** to prepare the next release.
- **Tag absent:** master carries an unreleased version, the merged release PR. Continue with **Part 2** to tag and publish it.

If the tag is absent and no release PR for `${TAG_PREFIX}${CURRENT_VERSION}` was ever merged (the gem has never been released), continue with Part 1 instead.

---

# Part 1: Prepare the Release PR

## Step 4: Determine Last Tag

Find the most recent tag for this gem:

```bash
git tag | grep "^${TAG_PREFIX}" | sort -V | tail -1
```

If no tag found, this is a first release. Fall back to the earliest commit that touches `$GEM_DIR`:
```bash
git log --oneline --reverse -- "$GEM_DIR/" | head -1
```

Store as `LAST_TAG` (or `FIRST_COMMIT_SHA` if no tag).

Display: "Collecting commits since `$LAST_TAG` (or since first commit for `$GEM_DIR`) ..."

---

## Step 5: Suggest Version Bump

Gather conventional commits scoped to `$GEM_DIR` since the last tag:

```bash
# If LAST_TAG exists:
git log ${LAST_TAG}..HEAD --oneline -- "$GEM_DIR/"

# If no tag (first release), use FIRST_COMMIT_SHA..HEAD:
git log ${FIRST_COMMIT_SHA}..HEAD --oneline -- "$GEM_DIR/"
```

Apply bump rules (applied in order, first match wins):
- Any commit matching `feat!:` or `fix!:` or `!:` → **MAJOR**
- Any commit matching `feat:` → **MINOR**
- Otherwise → **PATCH**

Show suggested bump with reasoning:

```
Version bump suggestion for $GEM_NAME:

  Current version:  $CURRENT_VERSION
  Suggested bump:   PATCH  →  x.y.z+1
  Reason:           no feat: or breaking commits found

  Commits included:
    abc1234 fix: correct fee calculation rounding
    def5678 test: add edge case for empty script

Confirm version? [suggested] or enter a custom version:
```

Wait for user to confirm the suggested version or provide a custom one. Store as `NEW_VERSION`.

**Already-released checks on `$NEW_VERSION`.**

**Check 1 — Tag does not already exist:**
```bash
git tag | grep "^${TAG_PREFIX}${NEW_VERSION}$"
```
Abort if tag exists:
> Already-released check failed: tag `${TAG_PREFIX}${NEW_VERSION}` already exists.
>
> This version has already been tagged. Choose another version.
>
> Recovery: no changes have been made.

**Check 2 — Version not already on RubyGems** (soft check — warn on timeout or unavailability):
```bash
gem search --remote --exact "$GEM_NAME" 2>&1
```
If output contains `$NEW_VERSION`, abort:
> Already-released check failed: `$GEM_NAME $NEW_VERSION` is already published on RubyGems.
>
> Choose another version.
>
> Recovery: no changes have been made.

If the command times out or fails, warn and continue:
> Warning: could not check RubyGems availability (network issue or gem not yet published). Continuing with caution.

Display: "Already-released checks passed. `$NEW_VERSION` is not yet released."

---

## Step 6: Interface Compliance Check

Extract abstract method names from Interface modules:
```bash
grep -rn "def " gem/bsv-wallet/lib/bsv/wallet/interface/ | grep -v "#"
```

Find all concrete implementations in the Store:
```bash
grep -rn "def " gem/bsv-wallet/lib/bsv/wallet/store/ | grep -v "#"
```

Compare method names. Any method defined in the interfaces that is missing from the Store files is a compliance gap.

If gaps are found:
```
Interface compliance warning: the following interface methods are not implemented in Store:

  - method_name_1
  - method_name_2

Abort to fix before releasing? [Y/n]
```

Default is abort. User can override by typing `n`.

---

## Step 7: Generate Changelog Draft

Gather commits for the changelog:

```bash
# If LAST_TAG exists:
git log ${LAST_TAG}..HEAD --oneline -- "$GEM_DIR/"

# If no tag:
git log ${FIRST_COMMIT_SHA}..HEAD --oneline -- "$GEM_DIR/"
```

Group by conventional commit type and map to Keep a Changelog sections:
- `feat:` / `feat!:` → **Added** (breaking: also **Breaking Changes**)
- `fix:` → **Fixed**
- `refactor:` → **Changed**
- `perf:` → **Changed**
- `docs:` → omit (internal)
- `test:` → omit (internal)
- `chore:` / `build:` / `ci:` → omit unless it affects users (use judgement)
- `security:` → **Security**

Format as Keep a Changelog section (American English):

```markdown
## $NEW_VERSION — YYYY-MM-DD

### Added
- Description of feat commit

### Fixed
- Description of fix commit

### Changed
- Description of refactor/perf commit
```

Display the draft and prompt:
```
Changelog draft for $GEM_NAME $NEW_VERSION (shown above).
Edit if needed, then confirm to proceed. [confirm / paste edited version]
```

Store the confirmed changelog section as `CHANGELOG_ENTRY`.

---

## Step 8: Create the Release Branch

The bump is a change like any other, so it goes on its own branch and lands by PR.

```bash
git switch -c "release/${TAG_PREFIX}${NEW_VERSION}"
```

Store the branch name as `RELEASE_BRANCH`.

---

## Step 9: Bump Version File

Show what will change:
```
Will update $VERSION_FILE:
  Before: VERSION = '$CURRENT_VERSION'
  After:  VERSION = '$NEW_VERSION'

Confirm? [y/N]
```

On confirmation, edit the version file — replace the `VERSION = '...'` line with the new version. Use the Edit tool (exact string replacement).

---

## Step 10: Update CHANGELOG.md

The changelog lives at `$GEM_DIR/CHANGELOG.md`.

Read the file. Find the line after the top header (e.g. `# Changelog`) and before the first existing `## x.y.z` entry. Insert `$CHANGELOG_ENTRY` there, followed by a blank line.

Show the diff before writing:
```
Will prepend to $GEM_DIR/CHANGELOG.md:

$CHANGELOG_ENTRY

Confirm? [y/N]
```

On confirmation, update the file.

---

## Step 11: Commit

Show the staged diff:
```bash
git diff HEAD $GEM_DIR/lib $GEM_DIR/CHANGELOG.md
```

Wait for confirmation, then commit:
```bash
git add "$VERSION_FILE" "$GEM_DIR/CHANGELOG.md"
git commit -m "chore(release): $GEM_NAME ${TAG_PREFIX}${NEW_VERSION}"
```

Display the resulting commit hash.

Recovery guidance if this step fails:
> Commit failed. Your version file and changelog have been modified but not committed.
> To roll back: `git checkout -- $VERSION_FILE $GEM_DIR/CHANGELOG.md`, then `git switch master && git branch -D $RELEASE_BRANCH`
> To retry: fix the issue and re-run `/release $GEM_KEY`.

---

## Step 12: Push the Branch and Open the PR

```
Ready to push $RELEASE_BRANCH and open the release PR. This will:

  git push -u origin $RELEASE_BRANCH
  gh pr create --title "chore(release): ${TAG_PREFIX}${NEW_VERSION}"

Confirm? [y/N]
```

On confirmation, with the branch name written out in full (the push-guard hook asks about any push whose refspec holds an unexpanded `$`):
```bash
git push -u origin "$RELEASE_BRANCH"
gh pr create --base master --head "$RELEASE_BRANCH" \
  --title "chore(release): ${TAG_PREFIX}${NEW_VERSION}" \
  --body "$CHANGELOG_ENTRY"
```

Display the PR URL.

Recovery guidance if the user declines or this fails:
> The release commit exists on $RELEASE_BRANCH but the PR is not open.
>
> To push and open it manually:
>   git push -u origin $RELEASE_BRANCH
>   gh pr create --base master --head $RELEASE_BRANCH --title "chore(release): ${TAG_PREFIX}${NEW_VERSION}"
>
> To roll back locally:
>   git switch master
>   git branch -D $RELEASE_BRANCH

---

## Step 13: Stop Until the PR Is Merged

Display:
```
Release PR opened: <url>

The release continues once the PR is merged. Merging is your call, and the ruleset requires the PR.
After the merge, run `/release $GEM_KEY` again from master: it tags the merge commit, builds the gem and publishes.
```

Stop here. Nothing in Part 2 runs in this invocation.

---

# Part 2: Tag and Publish

Run after the release PR is merged. `$CURRENT_VERSION` is now the version to release.

## Step 14: Confirm the Merge

Find the merge commit of the release PR, the first-parent commit on master that last changed the version file:

```bash
git log --first-parent --format='%H %s' -1 -- "$VERSION_FILE"
```

Store the hash as `MERGE_SHA`. Display it and confirm it is the merge of `release/${TAG_PREFIX}${CURRENT_VERSION}`:
```
Release PR merged as:

  <sha> Merge pull request #N from sgbett/release/${TAG_PREFIX}${CURRENT_VERSION}

Tag this commit as ${TAG_PREFIX}${CURRENT_VERSION}? [y/N]
```

Read the `## $CURRENT_VERSION` block at the top of `$GEM_DIR/CHANGELOG.md` and store it as `CHANGELOG_ENTRY`; it is the release notes.

**Version not already on RubyGems** (soft check — warn on timeout or unavailability):
```bash
gem search --remote --exact "$GEM_NAME" 2>&1
```
If output contains `$CURRENT_VERSION`, abort:
> Already-released check failed: `$GEM_NAME $CURRENT_VERSION` is already published on RubyGems.
>
> Bump the version in `$VERSION_FILE` to release a new version.
>
> Recovery: no changes have been made.

If the command times out or fails, warn and continue:
> Warning: could not check RubyGems availability (network issue or gem not yet published). Continuing with caution.

---

## Step 15: Create Tag

```
Will create tag: ${TAG_PREFIX}${CURRENT_VERSION} at $MERGE_SHA

Confirm? [y/N]
```

On confirmation:
```bash
git tag "${TAG_PREFIX}${CURRENT_VERSION}" "$MERGE_SHA"
```

Recovery guidance if this step fails:
> Tag creation failed. The release is merged but no tag has been created.
> To tag manually: `git tag ${TAG_PREFIX}${CURRENT_VERSION} $MERGE_SHA`

---

## Step 16: Push the Tag

**This step requires explicit user approval.** A pushed tag is public, and the gem release follows from it.

```
Ready to push the tag to origin. This will:

  git push origin ${TAG_PREFIX}${CURRENT_VERSION}

Type YES to push, or anything else to stop here.
```

Only proceed if the user types `YES` (case-sensitive).

On confirmation, with the tag written out in full (the push-guard hook asks about any push whose refspec holds an unexpanded `$`):
```bash
git push origin "${TAG_PREFIX}${CURRENT_VERSION}"
```

Recovery guidance if the user declines or push fails:
> Push skipped (or failed). The tag exists locally but has not been pushed.
>
> To push manually:
>   git push origin ${TAG_PREFIX}${CURRENT_VERSION}
>
> To drop it locally:
>   git tag -d ${TAG_PREFIX}${CURRENT_VERSION}

---

## Step 17: Build the Gem

Build from the tagged commit. If `HEAD` is not `$MERGE_SHA`, master has moved on since the release merge: `git checkout ${TAG_PREFIX}${CURRENT_VERSION}` first and `git checkout master` after the build.

The gemspec uses `Dir.chdir(__dir__)` for file globbing, so build must run
from inside the gem directory. Use `--output` to place the `.gem` file at a
known location relative to the repo root:

```bash
cd $GEM_DIR && gem build $GEM_NAME.gemspec --output $GEM_NAME-$CURRENT_VERSION.gem && cd -
mv $GEM_DIR/$GEM_NAME-$CURRENT_VERSION.gem ./$GEM_NAME-$CURRENT_VERSION.gem 2>/dev/null || true
```

The gem file will be at `./$GEM_NAME-$CURRENT_VERSION.gem` (repo root).

**Sanity check** — inspect the `.gem` contents:
```bash
tar -tzf $GEM_NAME-$CURRENT_VERSION.gem
```

Verify:
- `lib/` directory is present
- `CHANGELOG.md` is present
- `LICENSE` is present
- No unexpected files (e.g. `.env`, `spec/`, `tmp/`)

If anything looks wrong, warn the user and ask whether to continue or abort.

---

## Step 18: Prompt User to Push to RubyGems

The skill cannot push to RubyGems — credentials are yours to control.

Display:
```
The gem has been built at:

  $GEM_NAME-$CURRENT_VERSION.gem

To publish to RubyGems, run this command yourself:

  gem push $GEM_NAME-$CURRENT_VERSION.gem

This requires your RubyGems API key (run `gem signin` if not already authenticated).

Confirm once you have pushed (or type 'skip' to skip RubyGems and continue to GitHub release):
```

Wait for the user to confirm.

---

## Step 19: Create GitHub Release

```bash
gh release create "${TAG_PREFIX}${CURRENT_VERSION}" \
  --title "$GEM_NAME $CURRENT_VERSION" \
  --notes "$CHANGELOG_ENTRY" \
  --target master

gh release upload "${TAG_PREFIX}${CURRENT_VERSION}" \
  "$GEM_NAME-$CURRENT_VERSION.gem"
```

Recovery guidance if this fails:
> GitHub release creation failed. The gem has been pushed to RubyGems (if you confirmed that step).
> To create the release manually:
>   gh release create ${TAG_PREFIX}${CURRENT_VERSION} --title "$GEM_NAME $CURRENT_VERSION" --notes "..."
>   gh release upload ${TAG_PREFIX}${CURRENT_VERSION} $GEM_NAME-$CURRENT_VERSION.gem

---

## Step 20: Summary

Display a summary table:

```
Release complete!

  Gem:             $GEM_NAME
  Version:         $CURRENT_VERSION
  Tag:             ${TAG_PREFIX}${CURRENT_VERSION}
  Commit:          $MERGE_SHA
  RubyGems:        https://rubygems.org/gems/$GEM_NAME/versions/$CURRENT_VERSION
  GitHub release:  https://github.com/sgbett/bsv-wallet/releases/tag/${TAG_PREFIX}${CURRENT_VERSION}

Next steps:
  - Announce the release in the appropriate channels
```

---

## Abort Recovery Quick Reference

| Step failed | State | Recovery |
|-------------|-------|----------|
| Pre-flight | Nothing changed | Fix issue, run `/release $GEM_KEY` again |
| Already-released | Nothing changed | Choose another version, run `/release $GEM_KEY` again |
| Interface compliance | Nothing changed | Fix gaps or override, rerun |
| Version bump / changelog | Files modified on the release branch, not committed | `git checkout -- $VERSION_FILE $GEM_DIR/CHANGELOG.md`, then `git switch master && git branch -D $RELEASE_BRANCH` |
| Commit | Files modified, not committed | Fix issue and re-stage, or `git checkout --` to discard |
| Branch push / PR | Committed on the release branch, PR not open | `git push -u origin $RELEASE_BRANCH && gh pr create ...` manually |
| Merge | PR open | Merge it, then run `/release $GEM_KEY` again from master |
| Tag | Merged, not tagged | `git tag ${TAG_PREFIX}${CURRENT_VERSION} $MERGE_SHA` manually |
| Tag push | Tagged locally only | `git push origin ${TAG_PREFIX}${CURRENT_VERSION}` |
| Build | Tagged, pushed | `cd $GEM_DIR && gem build $GEM_NAME.gemspec && mv $GEM_NAME-$CURRENT_VERSION.gem ../..` |
| RubyGems push | Built, not on RubyGems | `gem push $GEM_NAME-$CURRENT_VERSION.gem` |
| GitHub release | On RubyGems, no GH release | `gh release create ...` manually |
