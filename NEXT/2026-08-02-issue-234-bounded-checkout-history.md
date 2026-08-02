---
date: 2026-08-02
issue: 234
title: Bound the actions-ci checkout to depth 1 and fetch pinned commits on demand
---

`actions-ci` checked out full history (`fetch-depth: 0`) because
`node-workflow-pins.test.sh` resolves co-located action dependencies at their
pinned commits. Full history was only ever a proxy for "the pinned objects are
present", and #287 made the proxy more expensive by widening the workflow's
`paths:` triggers to `.github/workflows/**`, `docs/**` and `README.md` — so
docs-only PRs paid for the whole graph too.

Measured empirically rather than assumed: instrumenting the pin test showed it
touches exactly **three** git objects, all at the checked-out tip
(`.github/actions/setup-verjson-node/action.yml` and its enclosing tree at
`HEAD`), and the repository currently carries **no** `Verjson/.github/…@<sha>`
self-reference at all. The walker's real contract is therefore per-pin object
availability, not history depth.

The checkout is now `fetch-depth: 1` with `fetch-tags: true` (the tag list is
what `doc-tag-pins.sh` reads, and a bounded fetch drops it by default), and
`node-workflow-pins.test.sh` materialises each pinned commit on demand with a
depth-1 fetch of that exact SHA. Fail-closed validation is unchanged and now
directly covered: a pin the checkout cannot obtain — nonexistent, rewritten out
of the origin, or unreachable because the runner cannot fetch at all — fails,
and is never reported as "cannot check". Regression tests exercise a real
shallow clone of a real origin and assert the clone is genuinely shallow, the
old pin genuinely absent before resolution, and still shallow after it.

Cost, measured against `github.com/Verjson/.github` over three runs each:
full history 1,392,544 B / 1,995 objects / 1.13–1.37 s, versus depth-1 with
tags 711,505 B / 521 objects / 1.06–1.13 s — 48.9% less transferred and 73.9%
fewer objects, and the gap widens with every commit added.
