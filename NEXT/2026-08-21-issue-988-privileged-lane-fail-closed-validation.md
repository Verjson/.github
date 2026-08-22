---
date: 2026-08-21
issue: 988
impact: patch
title: Fail closed on a missing or malformed privileged_lane in ai-privileged-merge.yml
---

`ai-privileged-merge.yml` declared the `privileged_lane` workflow input ADR
0089 requires generated callers to supply, but never read or validated it —
the terminal job's private-Verjson `runs-on:` branch hardcoded its self-hosted
selector regardless of what the caller sent. A new first step in the
`privileged_merge` job now exact-matches the caller-supplied value against
`["self-hosted","general"]`, failing closed with a diagnostic on anything
missing, malformed, hosted, widened, or shadowed by a repository-level
variable, per ADR 0089 (amended with the gap and fix rationale). The step
runs on whatever capacity `privileged_merge` already resolved to for the
caller, so it adds no new capacity requirement for external self-hosted-only
consumers on the `runner_labels` escape hatch.
