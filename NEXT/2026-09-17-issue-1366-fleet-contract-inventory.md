---
date: 2026-09-17
issue: 1366
title: Record the org contract distribution decision and add read-only fleet drift detection
impact: minor
---

ADR 0185 records the decision to give the org automation contract a **release
identity instead of a commit identity**. A `uses:` SHA is a content address: it
cannot state which contract an adopter is on, whether that contract is behind, or
whether it is still supported. Every drift-detection and regeneration mechanism
previously proposed is a compensating control for that one missing property.

`scripts/fleet-contract-inventory.py` supplies the migration inventory the decision
depends on. It is read-only: it opens nothing, writes nothing, and needs no
authority beyond repository reads. For each `uses: Verjson/.github/<path>@<sha>`
reference it resolves the object id of `<path>` at the pinned ref and at the hub
default branch and compares them.

Two properties are load-bearing and covered by
`scripts/ci-gate/fleet-contract-inventory.test.py`:

- **It does not fail open.** A comparison is only made once both object ids are
  present and match `^[0-9a-f]{40}$`. The naive form reports *current* when both
  API calls fail, because `"" = ""`; an unresolvable pin classifies `UNKNOWN`.
- **It never executes a generated header.** Contract SHAs recorded in generated
  adopter artifacts are read as claims and compared against the file's own pins.
  Treating adopter-controlled text as an invocation would make any writer to any of
  ~95 repositories an input to hub-privileged automation.

Composite-action references name a directory rather than a file, so the path index
includes tree entries as well as blobs. Indexing blobs alone reported those two
references `UNKNOWN`; with trees indexed they resolve, and both are drifted.

Measured against the live fleet on 2026-09-17: 332 references across 67
repositories — 280 drifted, 52 current, 0 unresolved — with 38 repositories
carrying two or more distinct contract SHAs at once.

Every one of the 34 drifted `node-ci.yml` references resolves to a contract SHA
that predates ADR 0178, so none of them publishes `deferred-ci`. The drift is not
cosmetic: each of those callers can report `build-test` SUCCESS on a head where the
lane deferred and executed nothing.
