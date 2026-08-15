---
date: 2026-08-15
issue: 814
impact: minor
title: Reject metered hosted selectors and unbounded hosted jobs
---

Runner-routing conformance now refuses any `runs-on` naming the metered
`macos-*` or `windows-*` runner families, requires a bounded `timeout-minutes`
on every job that resolves to an OS-scoped lane, forbids those lanes from
degrading to Linux through `VERJSON_LANE_FALLBACK`, and fails any workflow that
references the OS lane variables off the sanctioned desktop-release path or
from any trigger other than `workflow_dispatch`. Rolling `ubuntu-latest` is
also refused independently of repository visibility.

The organization is raising its Actions spending limit so `Verjson/AiB` can
build Electron installers on hosted macOS and Windows (#810), which removes the
limit that was doing the containment. `scripts/ci-gate/runner-routing-policy.test.sh`
keyed every literal-selector assertion on `ubuntu-(24\.04|latest)`, so
`runs-on: macos-latest` passed the whole file. The rules now live in the
parameterized `scripts/ci-gate/hosted-selector-policy.py`, driven by fixtures
that prove each negative, so #815 can point the same check at a consumer
checkout without duplicating it. The refusal of the metered families is
visibility-independent; literal Linux hosted selectors are keyed on repository
visibility, and the closed ADR 0089 `ubuntu-24.04` inventory stands unchanged.
Only complete reviewed routing-expression shapes are accepted; arbitrary direct or
`fromJSON`-decoded input, variable, and needs sources fail undetermined. Constructed
selectors fail the same way, matrix sources are inspected, and dot/bracket variable
dereferences are normalized before every timeout, fallback, and trigger rule.
Decided in ADR 0103.
