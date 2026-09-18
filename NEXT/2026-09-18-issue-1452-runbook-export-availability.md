---
date: 2026-09-18
issue: 1452
title: The container deployment runbook stops describing the export API as unreleased
impact: patch
---

`docs/container-deployment-runbook.md` carried two readings of the same fact. Its
opening sentence already recorded that verjson-cli-cloud#504 is closed and that
`@verjson/cli-cloud@1.0.0` ships the `runner-host-evidence` export API, while its
closing sentence still instructed a reader to "adopt its exact dependency" once the
export is released. PR #1362 pinned that dependency — `@verjson/cli-cloud` is
`1.0.0` in `contracts/container-deployment-cli/package.json` — so the closing
sentence named a step that had already happened and left the outstanding work
ambiguous.

The closing sentence now states that the dependency is pinned and that what remains
is wiring the parent broker into the controller's full requests and retained state
and regenerating the consumer, pointing at #1451 which tracks exactly that. The
broker's fail-closed rejection of `host-export` before acquiring any credential is
unchanged and still described: the pinned CLI inventory command mutates host
transaction locks, and neither it nor the current attester supplies the complete
read-only evidence contract. #1281, runner#197 and #629 remain open.

Documentation only; no behavior, pin, or configuration changed.
