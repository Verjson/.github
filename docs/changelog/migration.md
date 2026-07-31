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
7. Rebase queued pull requests once, remove aggregate edits, normalize their
   fragments, and verify no selected fragment was already consumed.
8. Remove `legacy_dir` after all managed consumers and queued pull requests are
   migrated. File a durable owning-PM handoff for any unmanaged blocker.

Use `python3 scripts/changelog.py validate --repo-root .` locally. Render
unreleased changes with `python3 scripts/changelog.py render-next --repo-root .`
and released history with
`python3 scripts/changelog.py render-released --repo-root .`.
