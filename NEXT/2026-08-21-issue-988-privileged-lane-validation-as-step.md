---
date: 2026-08-21
issue: 988
impact: patch
title: Move privileged_lane validation into a step so external orgs need no new hosted capacity
---

#989 added the ADR 0089 fail-closed `privileged_lane` check as a separate job
pinned unconditionally to `ubuntu-24.04`. The automated review on that PR
flagged, correctly, that this forced every caller — including an external
self-hosted-only org using the `runner_labels` escape hatch — to obtain
GitHub-hosted capacity just to reach a check that is a no-op for their route,
a capacity requirement this workflow never previously had for them. This
follow-up moves the same validation into the first step of the existing
`privileged_merge` job instead, so it runs on whatever capacity that job's
existing `runs-on:` already resolved to for the caller, adding no new
requirement for anyone. `runs-on:` itself is unchanged.
