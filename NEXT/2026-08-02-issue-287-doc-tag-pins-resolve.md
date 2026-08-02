---
date: 2026-08-02
issue: 287
title: Documented tag pins are corrected to v2.1.0 and checked against real tags
---

Every reusable-workflow example advertised `@v2.1.1`, a tag this repository never
published — releases stop at `v2.1.0` — so a consumer copying the documented exact
pin got an unresolved workflow reference. Six examples across `README.md`,
`docs/reusable-workflow-versioning.md`, `docs/node-workflows.md` and the
`node-ci.yml` caller header now name `v2.1.0`, the latest existing immutable
release. This supersedes the "exact consumer examples advance to the planned
`v2.1.1` patch release" note in the 2026-07-28 `node-ci` fragment: that release was
never cut, and cutting one is a separate, human-triggered decision.

`scripts/doc-tag-pins.sh` makes the drift impossible to repeat. It scans every
tracked file for `…/workflows/<name>.yml@<ref>` pins whose ref is tag-shaped and
requires each to match a tag of this repository exactly, so a prefix of a real tag
does not pass; `@main` and full-SHA refs name no tag and are out of scope. Tag truth
comes from local git rather than the API, so the check needs no network and cannot
flake — and every way the lookup can break (an unreadable checkout, or a checkout
carrying no tags at all) fails closed as a lookup fault instead of reading as a
docs verdict. `actions-ci` runs the suite, and its path triggers now span every
surface that can carry a pin example rather than an enumeration of workflows.
Fixes #287; see ADR 0014 for the versioning contract being enforced.
