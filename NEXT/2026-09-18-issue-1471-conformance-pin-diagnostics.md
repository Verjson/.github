---
date: 2026-09-18
issue: 1471
title: Report a mutable privileged-merge caller pin as a non-SHA pin, not a pin-count problem
impact: patch
---

`scripts/privileged-merge-conformance.sh` extracted a consumer's canonical `uses:` pin
with a capture group of `([0-9a-f]{40})`. A repository pinned to a mutable ref — `@main`,
a tag, a short SHA — therefore produced *zero* captures rather than one malformed capture,
fell into the pin-count arm, and was told it had a missing or duplicated `uses:` line when
the line was present and simply mutable. The 40-hex guard one branch away, which says
`pin is not a 40-hex commit SHA`, could not fire.

The extractor now captures whatever ref the line carries, so that guard is reachable
through the shipped script and the pin-count arm keeps its own meaning: zero canonical
`uses:` lines, or two of them.

**This is strictly stricter, not verdict-neutral.** The differential that establishes that
is committed alongside the change, at
`scripts/ci-gate/privileged-merge-pin-extractor-differential.test.sh`, so the figures below
can be re-derived by anyone reading the repository rather than taken on trust. It runs 38
caller shapes — conforming, mutable, malformed, shell-metacharacter, other-repository,
comment-bearing and multi-`uses:` bodies — through the pre-change expression, recorded from
`aa9d3865178a52cc2ddade774cd28716fd3ca03d` and checked against that blob where the checkout
can reach it, and through the shipped expression, which it reads out of the audited script
rather than transcribing. 26 shapes change verdict: 15 refuse under both and only gain the
accurate diagnostic, 5 move from accept to refuse, 6 move from refuse to accept, and 12 are
unchanged.

The 5 newly-refused shapes are one class, not several: a body carrying a conforming 40-hex
pin *and* a second canonical `uses:` line whose ref the old capture could not see. The
corpus covers that second line as `@main`, as a tag, as a different SHA with a trailing
comment, as the *same* SHA with a trailing comment, and as a shell-metacharacter ref. Each
matched exactly one capture under the old extractor and was accepted, with the second line
invisible to the audit. Those bodies now yield two captures and refuse on pin count. This
closes a fail-open in the pin arm; it is not covered elsewhere, because the canonical
content comparison that might have caught it is skipped by the conditional no-ops that
precede it.

The 6 newly-accepted shapes are a deliberate loosening decided here: a pin followed by a
YAML comment — separated by a space, by a tab, by several spaces, a bare `#`, a comment
that itself contains a `#`, and a comment with trailing whitespace — extracted zero
captures under both the old and the unrefined new extractor and was refused as a pin-count
problem. YAML treats a `#` preceded by whitespace as a comment, so those lines are
conforming pins and are now read as such. Every one of the six captured a well-formed
40-hex ref, which is the bound that matters: the 40-hex guard is applied to whatever the
capture yields, so no non-SHA ref is newly accepted by widening it. The boundary is pinned
in both directions: `@<sha>#v1.2.3`, with no separating space, is not a comment under YAML
and still refuses as a non-SHA pin. A comment after a *mutable* ref gains only the accurate
diagnostic and still refuses.

The same narrow capture, and the same fail-open, were present in the promotion-retry pin
extractor. Rather than widen a second copy and leave the next change to find both, the two
sites are collapsed into one `extract_canonical_pins` helper taking the canonical workflow
name. The duplication is what allowed the drift in the first place, so removing it is part
of the fix; the differential asserts that the two sites extract identically on every shape,
which is the property that had silently stopped holding.

No consumer matched on either message: searching the repository for
`expected exactly one immutable canonical workflow pin`, `pin is not a 40-hex`, and
`Invalid privileged merge caller pin` returns the audit script and its own gate test and
nothing else.

The gate test previously reached this guard only by widening the extractor in a mutated
*copy* of the audited script, through an `AUDIT_SCRIPT` indirection in the harness. Both
are retired: the guard is now exercised against the shipped script, and the harness
invokes it directly.

## An empty fetched artifact no longer decodes to a verdict (#1481)

`base64 --decode` succeeds on an empty stream, so the two fetch-and-decode sites in the
same script turned a fetch that returned nothing into an empty artifact that was then read
as content. The audit did not go quiet; it made a confident claim about the adopter it had
never established. Observed before the fix, against a fetch stubbed to return an empty
payload:

- an empty caller decoded to `Invalid privileged merge caller pin … 'expected exactly one
  immutable canonical workflow pin'` — a pin-count verdict about a file never read;
- an empty promotion retry decoded to `Invalid promotion retry caller pin … 'retry must
  pin the same immutable contract SHA as privileged merge'`;
- an empty canonical workflow decoded to `Mismatched canonical privileged merge workflow …
  'remote bytes differ from the checked-out audit revision'` — a byte-comparison verdict
  drawn from bytes that were never fetched.

Both sites now test for empty *content*, not zero bytes: a payload decoding to a single
newline (`Cg==`) is one byte and would have passed a `[ -s ]` check while carrying nothing
readable, so the guards compare against the artifact with whitespace stripped. Both fault
with a verdict that names the failed read
(`Empty privileged merge caller`, `Empty promotion retry`, `Empty canonical privileged
merge workflow`, each reasoning `fetched artifact decoded to no content, which is a failed
read rather than an absent file`). A repository that genuinely lacks the caller still
reports absence, which is asserted by its own test so the two cannot collapse into one
message. Each of the three verdicts was confirmed to redden against the pre-fix script.

The whole decode-after-fetch class was swept rather than these two lines. Two further
sites outside this script are confirmed vulnerable by direct reproduction and are tracked
separately, not fixed here: `scripts/required-checks-audit.sh:365-366`, where an empty decode
feeds `required-checks-workflow.py` and an empty stdin returns
`{"changelog_contract": "absent", …}` at exit 0 — a correctly-wired adopter reported as
having no wiring — and `scripts/classify-repo-stacks.sh:75`, where the decode is consumed
through process substitution with both `gh` and `base64` errors sent to `/dev/null`, so a
repository that does call reusable CI is classified `none`. The remaining sites in the
sweep reach a fail-closed `cmp -s`, `jq -er`, `grep -q`, explicit `[ -z … ]` guard, or an
`encoding == "base64"` requirement, and are reported in full on the pull request.
