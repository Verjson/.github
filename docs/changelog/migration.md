# Changelog migration

1. Inventory `NEXT/`, fragmented `CHANGELOG/`, authored `CHANGELOG.md`, release
   scripts, workflow callers, and open pull requests touching those paths.
2. Preserve released sections as one immutable `CHANGELOG/<version>.md` file
   per established version. Never infer or rewrite historical attribution.
3. Move every unreleased entry to a canonical `NEXT/` fragment with metadata.
   Consolidate duplicate issue identities rather than assigning new numbers.
   Declare `impact: major`, `minor`, or `patch` for new work. Existing fragments
   may omit it and explicitly default to patch; add impact during migration only
   when the intended next release axis is known.
   The `-issue-` segment is literal even when the entry has no issue, so only
   the identity changes with the metadata key:

   ```
   NEXT/2026-07-30-issue-249-adopt-immutable-snapshots.md    # issue: 249
   NEXT/2026-07-30-issue-20260730T184500Z-tidy-fixtures.md   # id: 20260730T184500Z
   ```
4. Land the snapshot and fragment normalization **before enabling the reusable
   validation workflow**. Stop feature pull requests from editing
   `CHANGELOG.md`; generate it from snapshots for display or packaging. This
   ordering prevents `check-pr` from rejecting the one pull request that must
   consume or reshape legacy changelog state.

   **Delete `.releaserc.json` in the same commit.** The dispatched release is the
   only writer of released history; semantic-release derives versions and notes
   from commit subjects and cannot consume a fragment, so a surviving config is a
   second, silent publisher. `verjson-browser-agent` and
   `verjson-identity-contracts` both kept theirs through migration because this
   step was implicit. The generated contract test now asserts its absence.

5. From the normalized consumer repository, generate all three consumer files —
   `changelog.yml`, `render-next.sh`, and
   `changelog-contract.test.sh` — with `scripts/gen-changelog-caller.sh`, and
   never hand-write or hand-edit them. Adopters that copied a contract test by
   hand all asserted a pre-release tree that the first release destroys (#309).

   **The pin you generate against must contain the generator itself.** Consumers
   were told to pin `1486d44…`, which predates `gen-changelog-caller.sh` — so
   fetching the generator at `contract_ref` 404s, and `verjson-authn` had to carry
   a second `generator_ref` to keep its contract test hermetic (#308).

   `contract-pin.test.sh` asserts this pin still resolves and still contains the
   generator. It also executes that pin's engine against fixtures carrying
   every metadata key advertised in the README capability table, so the
   recommendation cannot drift from either the repository or the documented
   feature set.

   Restricted-egress runners may preload the generated tooling cache without
   changing consumer files:

   ```bash
   export VERJSON_CHANGELOG_TOOL_CACHE=/opt/verjson/changelog-tools
   # expected file: /opt/verjson/changelog-tools/$PIN/changelog.py
   ```

   The generated renderer and contract test verify the preloaded engine against
   the exact digest embedded for `$PIN`; a matching path alone is never trusted.
   On a miss or mismatch they use the immutable raw GitHub URL as a repair
   fallback, or fail with the expected path and digest when egress is unavailable.

   **This pin is an immutable commit, not a published release.** `v2.2.0` is
   older and accepts only `date`, `issue`, `id`, and `title`; it rejects the
   currently documented `refs`, `summary`, `component`, and `impact` keys. No later release tag exists
   as of 2026-08-07. Use the exact `PIN` in the executable block below rather
   than substituting `v2.2.0`, and consult the capability table in
   `docs/changelog/README.md` before selecting any other immutable ref.

   Run this block from the consumer checkout. It creates a disposable canonical
   checkout at the immutable pin, then returns to the captured consumer root
   before writing anything. Set `PUBLISH_NODE=true` only for a repository that
   publishes a Node package; a non-publisher must not acquire a release caller.

   <!-- executable-migration:start -->
   ```bash
   set -euo pipefail
   PIN=3495f24c2cd81be7cc94b90c1c4650ca272102b1
   CONTRACT_SOURCE_URL="${CONTRACT_SOURCE_URL:-https://github.com/Verjson/.github.git}"
   PUBLISH_NODE="${PUBLISH_NODE:-false}"
   CONSUMER_ROOT="$(git rev-parse --show-toplevel)"
   CONTRACT_ROOT="$(mktemp -d)"
   cleanup_contract_checkout() { rm -rf "$CONTRACT_ROOT"; }
   trap cleanup_contract_checkout EXIT

   git -C "$CONTRACT_ROOT" init -q
   git -C "$CONTRACT_ROOT" fetch --quiet --depth=1 "$CONTRACT_SOURCE_URL" "$PIN"
   git -C "$CONTRACT_ROOT" checkout --quiet --detach FETCH_HEAD
   test "$(git -C "$CONTRACT_ROOT" rev-parse HEAD)" = "$PIN"

   cd "$CONSUMER_ROOT"
   mkdir -p .github/workflows scripts
   "$CONTRACT_ROOT/scripts/gen-changelog-caller.sh" workflow "$PIN" \
     > .github/workflows/changelog.yml
   "$CONTRACT_ROOT/scripts/gen-changelog-caller.sh" renderer "$PIN" \
     > scripts/render-next.sh
   "$CONTRACT_ROOT/scripts/gen-changelog-caller.sh" contract-test "$PIN" \
     > scripts/changelog-contract.test.sh
   chmod +x scripts/render-next.sh scripts/changelog-contract.test.sh

   if [ "$PUBLISH_NODE" = true ]; then
     "$CONTRACT_ROOT/scripts/gen-changelog-caller.sh" release-node "$PIN" \
       > .github/workflows/release.yml
   fi

   bash scripts/changelog-contract.test.sh
   ```
   <!-- executable-migration:end -->

   The generated contract test exercises validation, rendering, `check-pr`, and
   the release engine against disposable fixtures. For a publisher it also
   validates the generated release caller, including the release-path dry run.
   A repository already migrated at an older pin needs only to regenerate; the
   embedded `contract_ref` moves with it.

   Repositories consolidating generated checks use the same pin for the
   additional modes:

   ```bash
   scripts/gen-changelog-caller.sh generated-artifacts "$PIN" > .github/workflows/changelog.yml
   scripts/gen-changelog-caller.sh adr-index-generator "$PIN" > scripts/gen-adr-index.sh
   scripts/gen-changelog-caller.sh generated-artifacts-with-adr-index "$PIN" > .github/workflows/changelog.yml
   ```

   A repository that **publishes** something needs a fourth file, and must
   generate it rather than copying a sibling's:

   ```bash
   scripts/gen-changelog-caller.sh release-node "$PIN" > .github/workflows/release.yml
   ```

   At an immutable pin containing #799, a publisher may add a fifth generated
   file, fixing one reviewed `propose` or `dispatch` autonomy in source rather
   than accepting it from an event input. The recommended pin in the executable
   block above predates that mode and remains valid for its advertised baseline;
   see `docs/changelog/README.md` for the proposer command and permission split.

   The command defaults to `@verjson` and Node 24. For another supported
   scaffold, pass identical `--scope` and `--node-version` options to both
   `release-node` and `contract-test`; the latter enforces that the two release
   jobs still carry those values.

   The root package remains the backward-compatible default. Repositories that
   publish compatibility packages repeat `--package-dir <relative-dir>` on both
   commands and may provide executable
   `scripts/release-prepare-packages.sh <version>` for dependency or manifest
   preparation. Every configured package is stamped, packed, and reconciled by
   exact registry integrity independently.

   The generated caller also bounds the post-publication GitHub Release body.
   Snapshots at or below 125,000 bytes are published exactly; larger snapshots
   are truncated conservatively on a line boundary and link to the complete
   immutable `CHANGELOG/<version>.md` at the exact release tag. Do not replace
   the generated `notes-file` preparation with the raw snapshot path: a body
   rejection happens after npm publication and will repeat on every restart.

   `release-node` exists only from the commit that closed #463/#464/#465 and is
   included in the pin above. An older pin has no such mode and the command
   fails loudly rather than emitting an empty file, so a repository still on an
   older pin must move to this one before it can generate a release caller at
   all.
   `contract-pin.test.sh` checks `release-node` alongside the other three modes,
   so the guide can no longer document a command the pin cannot run. Every
   release caller written before this commit verifies the tree *after*
   `changelog-release.yml` has already pushed the tag, which spends the version
   on the first failure; see `docs/changelog/README.md`. Adopters with nothing to
   publish have no release caller at all, which stays a supported shape.

   Land the snapshot/normalization pull request before running the block.
   `check_pr` then never runs against the pull request that consumes fragments,
   so no one-time bypass is needed. `verjson-identity-contracts` added a permanent
   `if: github.event.pull_request.number != 16` escape hatch for want of this
   ordering, which every later copier inherited (identity-contracts#26);
   `verjson-browser-agent` #21/#22 and `verjson-cli-projects` #45/#46 sequenced it
   this way and needed none.

6. Commit the generated validation workflow only after normalization has
   landed. Enable one temporary `legacy_dir` only while a durable migration
   issue names the remaining consumer.
7. If the repository publishes, commit the generated reusable release caller
   and protect its environment when approval is required. Releases must run on
   the default branch. Confirm the repository can read the organization variable
   `RELEASE_APP_CLIENT_ID` (the GitHub App's `Iv...` client ID) and the
   organization secret `RELEASE_APP_PRIVATE_KEY`. Do not add `ORG_ADMIN_TOKEN`
   or a local `push_token`: the pinned reusable workflow mints the dedicated
   App's short-lived token and constrains it to the current repository with only
   Contents write. The App must be installed for that repository and named as
   an always-bypass actor on the exact `main-protection` ruleset. Before rolling
   this contract out to consumers, dispatch the input-free
   `release-app-canary.yml` in `Verjson/.github` from its default branch and
   retain the step-summary receipt. That central canary proves the shared
   organization ruleset and App bypass through the protected `develop` target;
   consumer repositories do not copy or dispatch the canary, and their App
   installation plus ruleset-bypass configuration remains a separate adoption
   prerequisite.
8. Rebase queued pull requests once, remove aggregate edits, normalize their
   fragments, and verify no selected fragment was already consumed. A branch cut
   before the migration needs `origin/main` merged in first, which surfaces the
   `.releaserc.json` and release-workflow conflicts as modify/delete rather than
   silently reinstating them.
9. Remove `legacy_dir` after all managed consumers and queued pull requests are
   migrated. File a durable owning-PM handoff for any unmanaged blocker.

Step 2 preserves historical attribution, which means a back-filled snapshot keeps
its pre-contract shape rather than the shape `release` generates. Snapshots are
immutable, so that divergence is permanent once written — see #317 before
migrating a repository with released history.

Use `python3 scripts/changelog.py validate --repo-root .` locally. Render
unreleased changes with `python3 scripts/changelog.py render-next --repo-root .`
and released history with
`python3 scripts/changelog.py render-released --repo-root .`.
