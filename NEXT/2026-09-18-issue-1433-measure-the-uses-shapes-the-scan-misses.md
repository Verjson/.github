---
date: 2026-09-18
issue: 1433
impact: patch
title: Measure which `uses:` shapes the contract-version scan misses, and name the rest
---

`contract-version verify` now recognizes a quoted or space-padded `uses:` key, and
reports a `uses:` reference it cannot resolve as an `UNRESOLVED_REFERENCE` gap
instead of silence. Both changes are measured rather than speculative: across
1208 tracked YAML files and 7361 Markdown files in 94 organization repositories
plus this one, they leave all 432 hub references and every verdict on them
unchanged, and produce zero new findings.

The question #1433 asked was which `uses:` shapes the reference scan misses
outright, because this scan is what a ~95-repository sweep depends on and a miss
there reads as a conformant repository rather than as a failure. The measurement
parsed every one of those YAML files and compared the `uses:` values a real YAML
parser sees against the ones the line-based recognizer extracts. Result: 1553
`uses:` keys, 432 hub references, **zero** missed. Every shape that occurs in
the fleet is a single-line scalar — quoted or bare, 730 of them carrying a
trailing comment, five in files with CRLF endings. The shapes the recognizer
could not see all have **0** occurrences: a quoted key (`"uses":`), whitespace
before the colon (`uses :`), a value on the following line, a block scalar
(`uses: >-`), an alias to an anchor (`uses: *hub`), and a path assembled from a
`${{ }}` expression.

Two of those are exactly readable, so `USES_RE` was widened for them rather than
left as a silent hole. The other four cannot be read by a line scan at all, so
they are reported as gaps, on the same principle that makes an unreadable file an
`UNSCANNED` finding: a shape the scan cannot resolve is named, never read as "this
repository carries no reference". The gap half is anchored to the start of a line
and requires the file to name the hub, and both conditions are load-bearing —
without them the measured corpus yields 30 findings from prose ending a sentence
with `uses:`, from `statuses:` containing the substring `uses:`, and from this
suite's own Python fixture strings; with them it yields none. Anchors and
continuation lines are file-scoped in YAML, which is what makes "the file never
names the hub" a proof rather than a guess.

The key pattern is deliberately **case-sensitive**, alone among the patterns here.
Actions requires a lowercase `uses` key, so `Uses:` is a workflow parse error rather
than a reference: a case-insensitive key can only invent gaps and can never catch a
pin. Left in, an ordinary English list item — `- Uses:` — inside any file that names
the hub becomes a permanent red check an adopter clears only by rewriting prose,
which is the muted-check hazard ADR 0185 refuses. That line is constructed rather
than sampled, like the 64-hex digest case above it: zero occur in the measured
corpus. Zero occurrences is exactly why widening for a quoted key was cheap, so it
cannot also be a reason to dismiss the symmetric risk of widening the other way —
the asymmetry that decides it is that one direction can catch a real pin and the
other cannot. `USES_RE` keeps its flag, because the hub name it also matches really
is case-folded by GitHub.

The ceiling is stated rather than implied. The scan stays line-based: it will not
join continuation lines or resolve anchors to *read* an unresolvable reference,
only name it. And a hub path assembled at run time, where the owner and repository
never appear literally in the tree, leaves no text for any scan of the tree to
find — that one cannot be reported at all, and is recorded in
[ADR 0191](../docs/decisions/0191-contract-releases-are-the-unit-of-adoption/README.md)
and in the recognizer's own comment block rather than implied away. Each new guard
is mutation-backed; the two anchoring guards are individually equivalent mutants
and are killed together, which the suite records.
