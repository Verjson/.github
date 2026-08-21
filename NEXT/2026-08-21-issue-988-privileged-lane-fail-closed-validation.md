---
date: 2026-08-21
issue: 988
impact: patch
title: Fail closed on a missing or malformed privileged_lane in ai-privileged-merge.yml
---

`ai-privileged-merge.yml` declared the `privileged_lane` workflow input ADR
0089 requires generated callers to supply, but never read or validated it —
the terminal job's private-Verjson `runs-on:` branch hardcoded its self-hosted
selector regardless of what the caller sent. A new `validate_privileged_lane`
job now exact-matches the caller-supplied value against
`["self-hosted","general"]` before the terminal job is scheduled, failing
closed with a diagnostic on anything missing, malformed, hosted, widened, or
shadowed by a repository-level variable, per ADR 0089 (amended with the gap
and fix rationale).
