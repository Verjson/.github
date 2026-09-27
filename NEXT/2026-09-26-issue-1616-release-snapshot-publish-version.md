---
date: 2026-09-26
issue: 1616
impact: patch
title: Fix the release-snapshot publish job's VERSION reference to the unreachable verify-job step
---

`scripts/gen-changelog-caller.sh`'s `release-snapshot` mode generates a
`publish` job that runs in its own job context, separate from the `verify`
job that resolves the release version via its `release-version` step. The
publish job's "Verify the checked-out tag and immutable release note" step
read `VERSION` from `steps.release-version.outputs.version` — a step ID that
only exists inside `verify` — instead of `needs.verify.outputs.version`,
which every other reference in that same job (the checkout `ref`, and the
following publish step) already used correctly. `steps.release-version`
resolves to empty outside its own job, so the exact-tag check
(`test "$(git describe --tags --exact-match HEAD)" = "$VERSION"`) always
failed against an empty string, hard-failing every release cut with this
generator mode.

Fixed the reference and added a regression assertion in
`scripts/ci-gate/changelog-caller-contract.test.sh` that the generated
`release-snapshot` publish job's `VERSION` env resolves from
`needs.verify.outputs.version` and never references `steps.release-version`.
Adopters on the `release-snapshot` mode (e.g. toquorum) need to regenerate
`.github/workflows/release.yml` from this fixed commit.
