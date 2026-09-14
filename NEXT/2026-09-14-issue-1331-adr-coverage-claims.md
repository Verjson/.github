---
date: 2026-09-14
issue: 1331
impact: patch
title: Check ADR coverage claims against the tests that exist, and restore two properties #1329 dropped
---

#1329 deleted eight `scripts/ci-gate` harnesses and amended three ADRs. Five more kept
making present-tense claims about the same deleted files, and two of the three amended
ones kept a live claim in their own body. Nothing caught it, because the sweep was
manual and a manual sweep over 175 ADRs misses.

`scripts/ci-gate/adr-live-coverage-claims.test.py` now fails CI when an ADR names a
`scripts/ci-gate/*.test.*` path that no longer resolves, unless that ADR states the
file's retirement. The rule is keyed on what the document says, not on the enclosing
heading: ADR 0012's stale claim sits *inside* a dated amendment written a month before
the deletion that invalidated it, so a heading-based exemption would have passed the
worst case. Scope is the whole document, because a stale claim normally sits in
`## Consequences` — decided text an amendment may never edit — so a section-scoped rule
would be satisfiable only by rewriting the record that must not be rewritten.

ADRs 0009, 0012, 0024, 0042, and 0058 carry dated amendments; 0039's was extended,
since its 2026-09-12 amendment recorded the retirement without stating it in the
sentences naming the files. No decision is reversed — only the claims about which files
currently assert them. ADR 0179 records the rule and its accepted trade-off.

`required-workflow-provenance.test.sh` was retired for the dead ADR 0039 attestation
matcher, but also asserted two properties of live code that had no other coverage.

A promotion for a PR that is no longer `OPEN` was one silent `exit 0` whether the PR
had merged or been closed unmerged. No merge fires either way, so this was never a
fail-open — but the anomaly (the gate authorized a head a human then closed) was
indistinguishable from the benign duplicate-dispatch race. Each non-`OPEN` state now
names itself; `exit 0` is kept deliberately, since failing the job would turn every
legitimately-closed PR with an in-flight promotion into a red run for no safety gain.

The merge gate's own `renovate/stability-days` preflight read had no test at all:
`ci-eligibility.test.sh` covers the separate `node-ci.yml` path. Its fail-open on an
unreadable status is deliberate — a defer suppresses a review and authorizes nothing,
and GitHub still blocks the merge on the pending status — so it is now pinned rather
than left true by accident of an untested `|| echo 0`. Four mutations of the shipped
workflow were each killed.
