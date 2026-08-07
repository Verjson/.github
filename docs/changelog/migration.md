# Changelog migration

1. Inventory `NEXT/`, fragmented `CHANGELOG/`, authored `CHANGELOG.md`, release
   scripts, workflow callers, and open pull requests touching those paths.
2. Preserve released sections as one immutable `CHANGELOG/<version>.md` file
   per established version. Never infer or rewrite historical attribution.
3. Move every unreleased entry to a canonical `NEXT/` fragment with metadata.
   Consolidate duplicate issue identities rather than assigning new numbers.
   The `-issue-` segment is literal even when the entry has no issue, so only
   the identity changes with the metadata key:

   ```
   NEXT/2026-07-30-issue-249-adopt-immutable-snapshots.md    # issue: 249
   NEXT/2026-07-30-issue-20260730T184500Z-tidy-fixtures.md   # id: 20260730T184500Z
   ```
4. Add the reusable validation workflow. Enable one temporary `legacy_dir`
   only while a durable migration issue names the remaining consumer.
5. Stop feature pull requests from editing `CHANGELOG.md`; generate it from
   snapshots for display or packaging.
6. Adopt the reusable release workflow and protect its environment if the
   repository requires approval. Releases must run on the default branch.
   **Delete `.releaserc.json` in the same commit.** The dispatched release is the
   only writer of released history; semantic-release derives versions and notes
   from commit subjects and cannot consume a fragment, so a surviving config is a
   second, silent publisher. `verjson-browser-agent` and
   `verjson-identity-contracts` both kept theirs through migration because this
   step was implicit. The generated contract test now asserts its absence.
7. Generate all three consumer files — `changelog.yml`, `render-next.sh`, and
   `changelog-contract.test.sh` — with `scripts/gen-changelog-caller.sh`, and
   never hand-write or hand-edit them. Adopters that copied a contract test by
   hand all asserted a pre-release tree that the first release destroys (#309).

   **The pin you generate against must contain the generator itself.** Consumers
   were told to pin `1486d44…`, which predates `gen-changelog-caller.sh` — so
   fetching the generator at `contract_ref` 404s, and `verjson-authn` had to carry
   a second `generator_ref` to keep its contract test hermetic (#308). Use:

   ```bash
   PIN=d469f40db3b6c092e216910dc2a5eb0cfec6fa08
   scripts/gen-changelog-caller.sh workflow      "$PIN" > .github/workflows/changelog.yml
   scripts/gen-changelog-caller.sh renderer      "$PIN" > scripts/render-next.sh
   scripts/gen-changelog-caller.sh contract-test "$PIN" > scripts/changelog-contract.test.sh
   ```

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
   currently documented `refs`, `summary`, and `component` keys. No later release tag exists
   as of 2026-08-07. Use the exact `PIN` above when following this guide rather
   than substituting `v2.2.0`, and consult the capability table in
   `docs/changelog/README.md` before selecting any other immutable ref.

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

   The command defaults to `@verjson` and Node 24. For another supported
   scaffold, pass identical `--scope` and `--node-version` options to both
   `release-node` and `contract-test`; the latter enforces that the two release
   jobs still carry those values.

   `release-node` exists only from the commit that closed #463/#464/#465 and is
   included in the pin above. An older pin has no such mode and the command fails loudly
   rather than emitting an empty file, so a repository still on an older pin must
   move to this one before it can generate a release caller at all.
   `contract-pin.test.sh` checks `release-node` alongside the other three modes,
   so the guide can no longer document a command the pin cannot run. Every
   release caller written before this commit verifies the tree *after*
   `changelog-release.yml` has already pushed the tag, which spends the version
   on the first failure; see `docs/changelog/README.md`. Adopters with nothing to
   publish have no release caller at all, which stays a supported shape.

   Generate the files **before** `.github/workflows/changelog.yml` exists in the
   consumer, and land the snapshot/normalization pull request first. `check_pr`
   then never runs against the pull request that consumes fragments, so no
   one-time bypass is needed. `verjson-identity-contracts` added a permanent
   `if: github.event.pull_request.number != 16` escape hatch for want of this
   ordering, which every later copier inherited (identity-contracts#26);
   `verjson-browser-agent` #21/#22 and `verjson-cli-projects` #45/#46 sequenced it
   this way and needed none.
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
