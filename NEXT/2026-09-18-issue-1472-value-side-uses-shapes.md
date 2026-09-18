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
exists to prevent. The key is also anchored, to a *delimiter* rather than to the line
start: a pin this scan must read sits at the start of its line, after the quote or
backtick opening it as a string or inline-code value, after the `#` of a commented-out
pin, or after a literal `\n` escape inside a source-string fixture. The delimiter need
not be adjacent to the key — `[ \t]*` and an optional `- ` bullet may sit between them, so
a quote followed by a space is admissible — and what separates a key from prose is
therefore not that a delimiter can never precede a mid-sentence `uses:`, but that one
which does must still be followed by a literal `Verjson/.github@<ref>` on the same line.

An earlier round of this change rejected anchoring outright, on a justification that was
wrong by a factor of twenty: line anchoring was measured at 181 lost references and
described as dropping "the commented-out pin the header pass depends on". The −181
reproduces, but classifying those 181 lines gives 108 `.sh` grep-assertion and fixture
literals, 43 `.py`/`.ts`/`.js`/`.mjs` fixture string literals, 21 `.md` prose and ADR
diff fragments, and just 9 comment lines — 8 usage-example headers in this repository's
own reusable workflows plus 1 prose comment in `contract-version.py`. The cited
span-exclusion double-count has *zero* instances among them: all 9 carry a non-SHA ref
(`@main`, `@v2.2.0`, `@<placeholder>`) that `HEADER_RE` never matches. Rejecting
`^\s*(?:-\s+)?` was still right, but for a different reason — it cannot read a value
written inside a string, which is most of what the fleet has — and "therefore accept the
residual" did not follow, because delimiter anchoring was never in the set.

Delimiter anchoring costs 5 references on the 96-repository corpus and adds none: four
`+    uses: …@main` diff fragments quoted inside frozen ADR records and one
`jobs.<job>.uses: …@<placeholder>` documentation template, none of them a live pin. Three
of the five are ADR records in the hub itself, which nothing runs this scan against, so
the cost borne by consumers is 2 — one each in `agents` and `verjson-agents`. Adding `+`
to the delimiter class would recover the four and was rejected. The class does accept
`- `, which carries the identical lowercase residual, so the asymmetry needs its own
reason rather than the bullet hazard alone: `- ` is YAML sequence syntax, and a
composite-action step writes a live pin as `- uses: …`, so the scan must read it; `+`
opens no YAML node — it is only a diff marker or a Markdown list bullet — so admitting it
would buy documentation illustrations and nothing else, while reopening the
`- Uses:`-shaped prose hazard on the one side the case-sensitivity scoping does not cover.
In exchange, the lowercase mid-sentence `uses:` with no delimiter before it is now rejected in
*both* the pathless and the path shape, so the pathless form is strictly better than the
path form the scan has always had rather than merely no worse. Each alternative in the
class is load-bearing and separately pinned: deleting the quote drops 122 references
(105 of them `.sh` assertions), the backtick 24, the `\n` escape 22, the `#` 8, and the
list-item dash 4. The delimiter also makes the lookbehind that rejected a longer key
ending in `uses`, such as `statuses:`, redundant for that case — every position the class
admits puts a delimiter, a space or tab, or a `- ` bullet before the key, and `statuses:`
offers an `s` — and it was removed with it. That removal is measured, not proved: the
lookbehind is unexercised by this corpus, not unreachable. The corpus reads 632 references
with it and 632 without, so no line in the measured fleet reaches it. One shape would: the
`\n` alternative ends on the literal `n`, a word character, so a source-string fixture
writing that escape with no indentation after it — `"on: push\nuses: Verjson/.github@<sha>"`
— matches under the shipped pattern and does not under the lookbehind variant. The
lookbehind goes because nothing in the fleet distinguishes the two and an assertion no test
can kill is worse than none, not because it could not fail.

The expression class is also length-bounded rather than an unbounded lazy `.*?`, which
re-scanned the line tail from every `$` and cost O(n^2) on a line dense with
unterminated `${{` — 53ms at 1600 openers, 833ms at 6400, 13.1s at 25600, over 120s at
102400, against a 1 MiB per-file scan limit. The bounded form is linear on the same
inputs.

Both read-side changes are on the value side of the extraction, so they re-open the read
path for every hub reference the fleet carries; they land together behind one re-measure
of the corpus rather than two. Each half is proved by deleting it: the required path
segment turns the root-action pin back into `UNRESOLVED_REFERENCE`, and the narrow ref
class restores the `'${{'` detail string. Re-measured end to end
through `references()` and `verify()` over 96 cloned organization repositories, the count
moves 769 → 764 with zero finding differences in any repository; the 5 are exactly the
documentation illustrations named above, in three repositories. The hub's own tree needs
its two axes stated separately, because the pattern and the tree both moved, and a single
"unchanged" figure hid that. Holding the tree fixed at this branch's, the pattern alone
reads 118 under the old form, 121 under the unanchored form and 119 under the shipped
delimiter form: the widened value side adds 3 net — 5 new matches, of which 2 merely
re-quote a `${{` the old form truncated on the same line — and delimiter anchoring then
drops the 3 ADR illustrations and adds 1, this fragment's own `\n` example above, which
the unanchored form's lookbehind rejects. Holding the tree fixed at `origin/main` instead,
the same three forms read 116, 116 and 113. The genuine before/after crosses both axes:
116 at the base tree under the old pattern, 119 here under the shipped one — the 6
reference-bearing lines this change's own fixtures and prose add, less the 3 ADR
illustrations it drops. Its one finding, an absent `.github/verjson-contract.json`, is
unchanged. Nothing runs this scan against the hub.

Seven tests pin the boundary: `Verjson/.github-mirror@<sha>` is never read as a hub pin;
`- Uses:` and `statuses:` are never read as keys and lowercase prose is rejected, each
asserted in *both* the pathless and the path shape so the two can never diverge; the
expression branch stops at its own first `}}` rather than swallowing a header SHA; and a
pin written inside a `"`-quoted shell assertion, a `\n`-escaped source-string fixture, or
a backtick template literal is still read. That last test also pins a pre-existing
property it does not change: the ref class admits a backtick, so a backtick-delimited pin
absorbs its closing backtick and reads as `UNPINNED_REFERENCE` rather than matching a
release commit. That is the value side's behaviour, identical under the pattern this
change replaces, and is left to Verjson/.github#1483 rather than folded into a key-side
change.
