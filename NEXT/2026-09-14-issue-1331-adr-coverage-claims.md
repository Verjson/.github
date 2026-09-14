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
test file that no longer resolves, unless that ADR states why it is absent. Every
spelling counts — a full path anywhere in the tree, and the bare basename an ADR uses
interchangeably with it — because both make the same present-tense promise to a reader.
Exemption is keyed on the file rather than the spelling, so retiring a path also settles
the same document's shorthand for it. The rule is keyed on what the document says, not on the enclosing
heading: ADR 0012's stale claim sits *inside* a dated amendment written a month before
the deletion that invalidated it, so a heading-based exemption would have passed the
worst case. Scope is the whole document, because a stale claim normally sits in
`## Consequences` — decided text an amendment may never edit — so a section-scoped rule
would be satisfiable only by rewriting the record that must not be rewritten.

Widening it surfaced fifteen more dangling live claims, each now settled by an appended
dated amendment rather than left as accepted residue: eight in ADR 0079's historical
disposition table, whose column header describes the deleted harnesses without retiring
one; two more in ADR 0024; the retired audit and actionlint harnesses in ADRs 0025 and
0026; and the adopter-side `changelog-contract.test.sh` in ADRs 0052, 0062 and 0092.

That last file is not a retirement at all — it is generated into adopter repositories by
`gen-changelog-caller.sh` and was never hosted here — so the check takes that as the
second, and only other, stated reason a name may be absent. The first design instead
narrowed the *matcher* to full `scripts/ci-gate/` paths to avoid the question. That is
the same defect as the stale claim one level up: an exemption granted by a regex is one
nobody writes down and no reviewer can see. Precision belongs in the stated reason, so
the three would-be false positives are now three explicit entries in the documents that
make the claims.

ADRs 0009, 0012, 0024, 0042, and 0058 carry dated amendments; 0039's was extended,
since its 2026-09-12 amendment recorded the retirement without stating it in the
sentences naming the files. No decision is reversed — only the claims about which files
currently assert them. ADR 0181 records the rule and its accepted trade-off.

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
