# Changelog migration

1. Inventory `NEXT/`, fragmented `CHANGELOG/`, authored `CHANGELOG.md`, release
   scripts, workflow callers, and open pull requests touching those paths.
2. Preserve released sections as one immutable `CHANGELOG/<version>.md` file
   per established version. Never infer or rewrite historical attribution.
3. Move every unreleased entry to a canonical `NEXT/` fragment with metadata.
   Consolidate duplicate issue identities rather than assigning new numbers.
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
