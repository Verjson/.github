# NEXT/ — changelog fragments

One file per log entry. Because no two PRs edit the same file, the running log
**cannot** produce merge conflicts when several PRs are in flight — the friction
that made a prepend-only `NEXT.md` costly when this repo started fanning out
concurrent work.

## Adding an entry

In the **same commit** as a change that affects behaviour, pins, docs, or config,
add a new file:

```
NEXT/YYYY-MM-DD-issue-<identity>-<short-slug>.md
```

`-issue-` is a fixed literal; only the identity after it varies with the
metadata key:

```
NEXT/2026-07-20-issue-123-short-slug.md              # issue: 123
NEXT/2026-07-20-issue-20260720T184500Z-short-slug.md # id: 20260720T184500Z
```

The file is one entry with metadata, e.g.:

```markdown
---
date: 2026-07-20
issue: 123
impact: patch
title: Short imperative title
---

One or two paragraphs: what changed, why, and the issue/PR/ADR refs.
```

**Write the release note first.** A released snapshot keeps only the entry's
`title` and its **lead paragraph** — everything up to the first blank line. The
rest stays here in the running log, where it belongs and where git history keeps
it. So the opening paragraph should read as a release note on its own, and the
argument goes after it. Where that is not possible, an optional `summary:` line
overrides the lead for the released form only ([ADR 0059](../docs/decisions/0059-released-snapshots-carry-the-release-note/README.md)).

```
scripts/render-next.sh --as-released   # what a release would publish
```

- `YYYY-MM-DD` and the identity must match the metadata. Legitimately issue-less
  work sets `id` instead of `issue` and uses a UTC timestamp or short UUID as
  documented in `docs/changelog/README.md`; the filename still spells `-issue-`,
  and never allocate a global sequence.
- Rendering uses metadata date and stable identity, not a globally reserved
  filename position.
- New fragments declare exactly one release impact: `major`, `minor`, or
  `patch`. The required check rejects omission after the bounded migration
  window; old unreleased fragments retain their historical patch fallback.
- Two fragments for the same issue signal potentially overlapping ownership.
  Consolidate them instead of assigning unrelated numbers.
- Never edit another entry's file, and never reintroduce a shared, hand-edited
  changelog — that recreates the conflict this structure removes.
- `0000-archive.md` holds the pre-split history. It is not an unreleased
  fragment, so the contract skips it by name and it is **not** rendered. Read it
  directly. It sorted last only while `--allow-legacy-next` loaded it as a
  legacy entry, which ended with the #289 migration.

## Reading the log

```
scripts/render-next.sh          # renders fragments by metadata, newest first
```

Nothing renders a committed combined file: keeping the rendered log out of git is
what guarantees zero conflicts.
