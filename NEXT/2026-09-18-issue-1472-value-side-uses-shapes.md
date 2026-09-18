---
date: 2026-09-18
issue: 1472
impact: patch
title: Read both value-side `uses:` shapes the contract scan misdescribed
---
`scripts/contract-version.py` extracts a hub reference from the value side of a
`uses:` key, and two readable shapes were misdescribed there.

A root-action reference, `uses: Verjson/.github@<40-hex-sha>`, was reported as a gap
reading "no path@ref this scan can read". The pin is present, immutable and perfectly
readable; only the trailing `/` in the pattern's `Verjson/\.github/` could not read it.
The direction of that error is a false *gap* on a correct pin, which is the muting
hazard ADR 0185 names. The path segment is now optional, with the separating `/` kept
inside the optional group so the character after the hub name is still either `/` or
`@` and never arbitrary text.
