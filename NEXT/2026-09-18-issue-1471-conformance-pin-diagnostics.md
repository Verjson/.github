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

**This changes explanations, never verdicts.** A pin that refused before still refuses.
Both extractors were run over the same twelve caller shapes — the conforming SHA, an
uppercase SHA, a 41-character SHA, a short SHA, `main`, a tag, a branch path, a `refs/`
ref, an all-zero 40-digit ref, a duplicated canonical line, and a line pointing at another
repository — and the accept/refuse verdict was identical in all twelve, with zero flips.
The one case that accepts is the well-formed 40-hex pin, which the old capture already
matched exactly, so no widened capture can newly satisfy the guard.

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

Both sites now fault with a verdict that names the failed read
(`Empty privileged merge caller`, `Empty promotion retry`, `Empty canonical privileged
merge workflow`, each reasoning `fetched artifact decoded to no content, which is a failed
read rather than an absent file`). A repository that genuinely lacks the caller still
reports absence, which is asserted by its own test so the two cannot collapse into one
message. Each of the three verdicts was confirmed to redden against the pre-fix script.

The whole decode-after-fetch class was swept rather than these two lines. Two further
sites outside this script are confirmed vulnerable by direct reproduction and are tracked
separately, not fixed here: `scripts/required-checks-audit.sh:365`, where an empty decode
feeds `required-checks-workflow.py` and an empty stdin returns
`{"changelog_contract": "absent", …}` at exit 0 — a correctly-wired adopter reported as
having no wiring — and `scripts/classify-repo-stacks.sh:75`, where the decode is consumed
through process substitution with both `gh` and `base64` errors sent to `/dev/null`, so a
repository that does call reusable CI is classified `none`. The remaining sites in the
sweep reach a fail-closed `cmp -s`, `jq -er`, `grep -q`, explicit `[ -z … ]` guard, or an
`encoding == "base64"` requirement, and are reported in full on the pull request.
