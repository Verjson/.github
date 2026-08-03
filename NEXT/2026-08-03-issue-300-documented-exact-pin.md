---
date: 2026-08-03
issue: 300
title: The documented exact pin advances to v2.2.0, the release that carries the eligibility fix
---

`v2.1.0` predates the `ci-eligibility` inlining, so every consumer following the
documented exact-pin posture was on the pre-fix behaviour. #287 corrected the
examples *downward* — from a `v2.1.1` that was never cut to the `v2.1.0` that
existed — which made the pins resolve without making them current.

Half of #300 resolved itself when `v2.2.0` was cut and `@v2` was re-pointed to
it. The other half did not: the examples still named `v2.1.0`. The difference is
not cosmetic. At `v2.1.0` the eligibility job still calls
`ci-eligibility@9a7cc9c` as an external action; at `v2.2.0` that logic is inlined
in `node-ci.yml`. A reader copying the documented pin got the older shape.

Six example sites now name `v2.2.0`: `README.md`, both blocks in
`docs/node-workflows.md`, the TL;DR and the two `helm-ci` blocks in
`docs/reusable-workflow-versioning.md`, and the header comment in
`.github/workflows/node-ci.yml`.

The release-cutting example in `docs/reusable-workflow-versioning.md` no longer
says `gh release create v2.1.1`. That was the exact ghost tag #287 and #300 were
about, sitting in a copy-pasteable command; it now uses the `vX.Y.Z` placeholder
the surrounding step already uses, so it cannot go stale or be pasted into
existence.

Deliberately unchanged: ADR 0014 and the #287 fragment still say `v2.1.0` and
`v2.1.1`. Both are historical records of what was true when written, and an ADR
is superseded rather than edited.

`doc-tag-pins.sh` does not catch this class. It fails a pin naming a tag that
does not exist — docs running *ahead* of the release, the #287 failure — and
passes a pin naming a real but superseded tag, which is the #300 failure. A
"must name the newest tag" rule was considered and rejected: it would fail on
ADR 0014's deliberate historical `@v2.1.0` reference, and an immutable decision
record must not be edited to satisfy a linter.
