---
date: 2026-08-06
issue: 468
title: Marking a draft ready re-enters the merge gate again
---

Marking a draft pull request ready — or removing a `hold` — now re-enters the merge
gate on its own, instead of leaving the pull request wedged on three `SKIPPED` checks
until someone pushed a commit or dispatched the gate by hand.

The gate declared `ready_for_review`, `labeled` and `unlabeled` in its trigger types,
but none of the three had ever produced a run. `ai-review-merge.yml` is installed
org-wide as a **required workflow** by the `main-protection` ruleset, and a required
workflow is scheduled by the ruleset rather than by its own `on:` block: those runs
live under a workflow record the API does not even list, and the ruleset fires them
for `opened`, `synchronize` and `reopened` only. Measured on a throwaway pull request
against probe workflows that copy the gate's entire `on:` block and are not
required-enforced — the probes fire on every type, the gate on three. Of the 139 runs
under the gate's own workflow record, the 100 most recent are all `workflow_dispatch`.

`.github/workflows/gate-rearm.yml` bridges the gap: it subscribes to
`ready_for_review` and to `unlabeled` for a terminal hold, and converts them into a
`workflow_dispatch` of the gate. `hold`, `DO NOT MERGE` and draft stay terminal
(ADR 0012) — checked against the event and re-checked against live pull-request state
with the gate's own hold predicate — and the bridge cannot re-enter itself, because a
dispatch emits neither event and the gate's own `re-review` cleanup is excluded by
name. It checks nothing out, runs no third-party action, and holds only
`contents: read`, `actions: write`, `pull-requests: read`.

Rationale and the measured evidence table are in
[ADR 0063](../docs/decisions/0063-required-workflow-events-are-bridged/README.md).
The ruleset spans every repository in the organization, so the same three activity
types are dead everywhere; rolling the bridge out to the fleet is tracked separately.
