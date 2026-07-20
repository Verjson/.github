# NEXT/ — changelog fragments

One file per log entry. Because no two PRs edit the same file, the running log
**cannot** produce merge conflicts when several PRs are in flight — the friction
that made a prepend-only `NEXT.md` costly when this repo started fanning out
concurrent work.

## Adding an entry

In the **same commit** as a change that affects behaviour, pins, docs, or config,
add a new file:

```
NEXT/YYYY-MM-DD-<short-slug>.md
```

The file is one entry, starting with an H1 title that ends in the date, e.g.:

```markdown
# Short imperative title — 2026-07-20

One or two paragraphs: what changed, why, and the issue/PR/ADR refs.
```

- `YYYY-MM-DD` is the date the entry lands. Fragments render **newest first**, so
  a later date sorts above an earlier one; same-day entries sort by slug in
  reverse-alphabetical order (rarely matters — pick distinct slugs if it does).
- Never edit another entry's file, and never reintroduce a shared, hand-edited
  changelog — that recreates the conflict this structure removes.
- `0000-archive.md` holds the pre-split history and always sorts last.

## Reading the log

```
scripts/render-next.sh          # concatenates all fragments, newest first
```

Nothing renders a committed combined file: keeping the rendered log out of git is
what guarantees zero conflicts.
