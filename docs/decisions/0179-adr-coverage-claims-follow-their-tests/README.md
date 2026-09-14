# 0176 — An ADR's coverage claims are checked against the tests that exist

- **Date:** 2026-09-14
- **Status:** Accepted
- **Issue:** [#1331](https://github.com/Verjson/.github/issues/1331)
- **Amends:** [ADR 0009](../0009-gate-files-followup-issues/README.md), [ADR 0012](../0012-gate-honors-do-not-merge-label/README.md), [ADR 0024](../0024-absent-checks-fail-closed/README.md), [ADR 0039](../0039-required-workflow-gate-provenance/README.md), [ADR 0042](../0042-privileged-merge-reusable-split/README.md), [ADR 0058](../0058-github-waits-for-checks-not-the-gate/README.md)
- **Category:** decision-record integrity, merge-gate coverage

## Context

An ADR body is written in the present tense — "covered by X", "wired into
`actions-ci`", "pinned by mutation". That is the right voice for a decision record
and it is also a liability, because the sentence keeps asserting a live fact long
after the file it names is gone. The reader has no way to tell a current claim from
a fossil, and the ADR is precisely where someone goes to find out whether a property
is still guarded.

[#1329](https://github.com/Verjson/.github/issues/1320) deleted eight `scripts/ci-gate/*.test.sh`
harnesses whose subjects ADR 0079/0081 had removed. It correctly appended dated
amendments to ADRs 0039, 0044, and 0079. Five further ADRs kept making concrete
present-tense claims about the same deleted files, and two of the three amended ones
kept a live claim in their own body as well. Nothing caught it, because nothing was
checking — the sweep was manual, and a manual sweep over 175 ADRs misses.

The same review found that one deletion was wider than its stated justification.
`required-workflow-provenance.test.sh` was retired for the dead ADR 0039 run-attestation
matcher, but it also asserted two properties of live code: that a promotion arriving
for a closed-unmerged PR is attributable rather than silently absorbed into the
already-merged case, and that the merge gate's own `renovate/stability-days` preflight
read fails open when it cannot read the status. Neither had any other coverage.

## Decision

**1. Coverage claims about `scripts/ci-gate` tests are machine-checked.**
`scripts/ci-gate/adr-live-coverage-claims.test.py` (registered in `changelog-release`)
fails CI when any `docs/decisions/**/README.md` names a `scripts/ci-gate/*.test.*`
path that no longer resolves, unless the same ADR states that file's retirement.

The rule is deliberately *not* keyed on the enclosing heading. A dated amendment
written **before** a deletion is exactly as stale as the body — ADR 0012's stale claim
sits inside its 2026-08-07 amendment — so a heading-based exemption would have passed
the worst case here. It is keyed on what the document says about that specific path.

Scope is the whole document, not the enclosing section, because a stale claim
typically sits in `## Consequences`, which is decided text an amendment may never
edit. Requiring the retirement note to sit beside the claim would make the check
satisfiable only by rewriting the record that must not be rewritten. Document scope
is therefore the strongest rule an *appended* amendment can satisfy.

**2. The two properties are restored as tests, not as prose.** The closed-unmerged
disposition is driven in `scripts/ci-gate/native-automerge.test.sh`; the release-age
defer and its fail-open are driven in the new
`scripts/ci-gate/classify-release-age-defer.test.sh`.

**3. The release-age fail-open is intentional and is now pinned as such.** When the
gate cannot read `renovate/stability-days` — a lost `statuses: read`, a transient 5xx
— it proceeds to a normal review rather than deferring. Deferring is not a safety
property: a defer suppresses a review, it authorizes nothing, and GitHub still blocks
the merge on the genuinely-pending status whatever this step concludes. Failing closed
would stall every Renovate PR behind any transient failure, trading a wasted model call
for a silent delivery outage. This is the one direction where the cheap failure is the
correct one, and it was previously true only by accident of an untested `|| echo 0`.

**4. The closed-unmerged promotion stays a no-op, and says which no-op it is.** No
merge fires on any non-`OPEN` branch, so this was never a fail-open. Making a closed
PR a job failure would turn every legitimately-closed PR with an in-flight promotion
into a red run needing triage — a behavior change with real blast radius on the merge
gate for no safety gain. The defect was that the anomaly (the gate authorized a head a
human then closed) was indistinguishable from the benign duplicate-dispatch race, so
the diagnostic is what changed.

## Consequences

- An ADR that names a deleted `scripts/ci-gate` test fails CI until an amendment
  records the retirement. This is satisfiable by appending, never by editing decided
  text, which keeps the ADR-immutability rule and the freshness rule compatible.
- Six ADRs carry a 2026-09-14 amendment pointing here. None of their decisions is
  reversed; only their claims about which files currently assert those decisions are
  corrected.
- The check is scoped to full `scripts/ci-gate/` paths. Bare basenames (ADR 0024 and
  ADR 0079 name harnesses without a directory) and dangling references to tests
  outside `scripts/ci-gate` are **not** covered. Widening the matcher sweeps in every
  historical disposition table and roughly a dozen pre-existing dangling references in
  ADRs #1329 never touched; that is a larger, separate cleanup, and half-enforcing it
  here would blur what this check asserts. The residue is recorded here rather than
  silently omitted.
- The trade-off accepted in decision 1 is stated plainly: a retirement note anywhere
  in a long ADR will launder a live claim elsewhere in the same ADR for the same file.
  The failure this closes is "nothing in this ADR says the file is gone", which is the
  one a reader actually hits.
