---
date: 2026-08-21
issue: 980
impact: patch
title: Refresh the rework-telemetry repo list to activity-ranked repos (ADR 0113)
---

`.telemetry/rework-thresholds.json`'s `repos` list had gone stale — several
of its 8 repos had little to no recent activity. Replaced it with the top 10
org repos by a fresh 6-week bot-filtered commit-activity ranking, excluding
`verjson-agents` (tooling, not a shipped product) per explicit user
direction. Full methodology and the ranked list are in ADR 0113. This is a
human-owned dial under ADR 0006; changed here at the user's explicit
request, not unilaterally.
