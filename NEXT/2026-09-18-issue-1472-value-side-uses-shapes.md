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

Widening what the scan *reads* must not widen what it *claims*, so the key side is
tightened in the same change. The key is now matched case-sensitively — scoped with
`(?-i:...)` so the trailing `re.IGNORECASE` still case-folds the hub name GitHub itself
case-folds — and rejects a longer key that merely ends in `uses`. Without both, the
pathless form read `- Uses: Verjson/.github@<sha>` out of an English list item and
`statuses: Verjson/.github@<sha>` out of a lookalike key, turning each into a
`PIN_MISMATCH`: strictly worse than the false *gap* the rationale on `USES_KEY_RE`
exists to prevent. The key is deliberately still not anchored to the line start the way
`USES_KEY_RE` is, because anchoring it drops the commented-out pin the header pass
depends on — measured at 181 references lost across the fleet. The residual, a lowercase
`uses:` mid-sentence, is pinned by a test that asserts the new pathless form reads no
differently from the path form the scan has always read.

The expression class is also length-bounded rather than an unbounded lazy `.*?`, which
re-scanned the line tail from every `$` and cost O(n^2) on a line dense with
unterminated `${{` — 53ms at 1600 openers, 833ms at 6400, 13.1s at 25600, over 120s at
102400, against a 1 MiB per-file scan limit. The bounded form is linear on the same
inputs.

Both read-side changes are on the value side of the extraction, so they re-open the read
path for every hub reference the fleet carries; they land together behind one re-measure
of the corpus rather than two. Each half is proved by deleting it: the required path
segment turns the root-action pin back into `UNRESOLVED_REFERENCE`, and the narrow ref
class restores the `'${{'` detail string. Re-measured end to end through `references()`
and `verify()` over 96 cloned organization repositories, the before and after results are
identical — 769 references, zero finding differences. On the hub's own working tree the
count moves 118 → 121, because the scan now reads the fixtures and prose this change
itself adds; the findings are unchanged at one, and nothing runs this scan against the
hub. Four tests pin the false-positive boundary: `Verjson/.github-mirror@<sha>` is never
read as a hub pin, `- Uses:` and `statuses:` are never read as keys, and the expression
branch stops at its own first `}}` rather than swallowing a header SHA that follows it.
