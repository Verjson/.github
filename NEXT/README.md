# NEXT/ — changelog fragments

One file per log entry. Because no two PRs edit the same file, the running log
**cannot** produce merge conflicts when several PRs are in flight — the friction
that made a prepend-only `NEXT.md` costly when this repo started fanning out
concurrent work.

## Adding an entry

In the **same commit** as a change that affects behaviour, pins, docs, or config,
add a new file:

```
NEXT/YYYY-MM-DD-issue-<issue-number>-<short-slug>.md
```

The file is one entry with metadata, e.g.:

```markdown
---
date: 2026-07-20
issue: 123
title: Short imperative title
---

One or two paragraphs: what changed, why, and the issue/PR/ADR refs.
```

- `YYYY-MM-DD` and the issue identity must match the metadata. Legitimately
  issue-less work may use a UTC timestamp or short UUID as documented in
  `docs/changelog/README.md`; never allocate a global sequence.
- Rendering uses metadata date and stable identity, not a globally reserved
  filename position.
- Two fragments for the same issue signal potentially overlapping ownership.
  Consolidate them instead of assigning unrelated numbers.
- Never edit another entry's file, and never reintroduce a shared, hand-edited
  changelog — that recreates the conflict this structure removes.
- `0000-archive.md` holds the pre-split history and always sorts last.

## Reading the log

```
scripts/render-next.sh          # renders fragments by metadata, newest first
```

Nothing renders a committed combined file: keeping the rendered log out of git is
what guarantees zero conflicts.
