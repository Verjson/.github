---
date: 2026-08-07
title: Make trigger-scope enforce the path invariants it claims
issue: 360
---

`scripts/trigger-scope.test.sh` left two path-trigger regressions green.

**The pull_request/push comparison counted lines instead of comparing sets.** The comment above
it says the two lists "must stay identical", but the code compared `grep -c "^      - "` on each
block — so swapping one push path for a different path preserved the count and passed while the
sets diverged. `main` could then run a check the originating PR skipped, or the reverse. Now
compared as sorted sets, and a divergence prints which paths are on which side. The old label
("the same number of paths") was honest about what it checked; it just was not the invariant.

**`doc-tag-pins.sh` reads every tracked file, while coverage was asserted only for markdown and
workflow/action YAML.** Requiring a trigger for literally every path would run this suite on
every PR — the cost #233/#234 exist for — so the narrower population that actually matters is
asserted instead: every tracked file that *already carries* a tag-shaped pin. That is exactly
the set `doc-tag-pins.sh` can fail on, so covering it closes the gap without widening the
trigger to everything.

The pin pattern is **extracted from `doc-tag-pins.sh`** rather than restated. That is
load-bearing: the first version of this check anchored on `uses:` at line start, while the
scanner matches `workflows/<name>.yml@v<ref>` anywhere in any tracked file — so a pin in a
comment was invisible to the very check meant to find it. The mutation passed until the pattern
was derived from the scanner instead of guessed.

Verified by mutation, both halves:

- Swapping `renovate.json` for `DIFFERENT-PATH.json` in the push block only (count unchanged)
  → `FAIL - trigger lists diverge as sets, not merely in count (#360)`.
- A `workflows/node-ci.yml@v2.2.0` reference added to `.github/FUNDING.yml`, which no trigger
  covers → `uncovered pin carrier: .github/FUNDING.yml`.

No production behaviour changes: the triggers themselves are already correct. What changed is
that the test can tell.
