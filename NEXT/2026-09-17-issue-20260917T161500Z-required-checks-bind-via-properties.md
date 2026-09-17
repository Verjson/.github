---
date: 2026-09-17
id: 20260917T161500Z
title: Record that required status checks bind through repository properties (ADR 0186)
impact: patch
---

`Verjson/verjson-ci#186`, `Verjson/verjson-compliance#23`, and
`Verjson/verjson-compliance-schema#12` each reported a repository whose `main`
ruleset declares no required status checks, so a green rollup gated nothing.

Direct API inspection showed the three-defective-rulesets framing was wrong.
All three repositories return exactly one ruleset, and it is the same one:
organization ruleset `18098028` `main-protection`, which carries the universal
rules and deliberately no `required_status_checks`. None of the three has any
repository-level ruleset. The real defect was that all three had an **empty**
custom property set, so they matched none of the property-selected rulesets that
do carry required contexts — `core-checks-node`, `changelog-contract-required`,
`ai-authorization-arm-required`.

ADR 0186 records the decision to enroll by setting repository property values,
and to reject both adding contexts to the organization-wide `main-protection`
(which would require them of ~95 heterogeneous repositories and wedge every one
that does not emit them) and authoring per-repository rulesets (which fork the
fleet into two enrollment mechanisms that do not inherit contract changes).

It also records the constraint that made this non-trivial: for a reusable
workflow call the context prefix is the **caller job id**, so `verjson-ci`
published `build-test / *` where the contract requires `ci / *` and had to be
renamed before enrollment rather than enrolled as-is.

The `integration_id: null` binding on `core-checks-actions`' `shell-tests`
context is left untouched and remains tracked as #1381; every context newly
required of these three repositories is app-bound.
