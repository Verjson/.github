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

An unpinned expression ref, `uses: Verjson/.github/.github/workflows/x.yml@${{ env.REF }}`,
kept its correct `UNPINNED_REFERENCE` verdict but was quoted back as `'${{'`, because
the ref class stopped at the expression's first space — telling the reader the offending
ref is something nobody wrote. The ref now admits a whole `${{ ... }}` expression as one
unit, lazily to its own `}}` and never across a line, so a commented header claim that
follows a templated pin on the same line is still read as a separate claim.

Both changes are on the value side of the extraction, so they re-open the read path for
every hub reference the fleet carries; they land together behind one re-measure of the
corpus rather than two. Each half is proved by deleting it: the required path segment
turns the root-action pin back into `UNRESOLVED_REFERENCE`, and the narrow ref class
restores the `'${{'` detail string. Two further tests pin the false-positive boundary —
`Verjson/.github-mirror@<sha>` is never read as a hub pin, and the expression branch
never swallows a later SHA on its line.
