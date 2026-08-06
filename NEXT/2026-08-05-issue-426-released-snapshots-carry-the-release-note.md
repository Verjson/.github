---
date: 2026-08-05
issue: 426
title: 'feat(changelog): released snapshots carry the release note, not the diary'
---

A released snapshot now keeps each entry's title and lead paragraph; the running
log keeps the whole body. `render-next --as-released` shows the released shape
while the fragments can still be changed.

## Why

There was one `render()` and it served two callers with opposite needs — the
consumer-facing `CHANGELOG/<version>.md` and the engineering diary in `NEXT/`.
The diary won by default, because the org convention asks a fragment to carry
its rationale and nothing constrained body length. verjson-ai's v0.11.0 was the
first release cut under this contract and shipped 174 KB / 2417 lines for 62
entries.

This is not one repository writing badly: this repository's own fragments run
58-84 lines for the same reason.

## What it costs

Nothing, on day one. Across those 62 entries the lead paragraph is 1/6/10/12
lines (min/median/p90/max), none is empty, and all 62 are prose — so `summary:`
is a genuine escape hatch rather than a dependency, and no existing fragment
needs editing. The measured effect is 174 KB → 39 KB and 2417 → 461 lines.

The lead is a plain blank-line split with no block-type detection. A first pass
that tried to recognise non-prose openers produced 7 false positives, every one
of them prose beginning `#79 threaded …` — not a heading in CommonMark, but the
easy way to write that bug.

`summary:` is validated exactly as `title:` is, since both reach a snapshot that
can never be edited: it may not be empty, and ambiguous quoting is rejected at
PR time (#425).
