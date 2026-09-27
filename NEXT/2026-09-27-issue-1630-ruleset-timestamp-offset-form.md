---
date: 2026-09-27
issue: 1630
impact: patch
title: Ruleset verify-run accepts the offset-form updated_at GitHub actually returns
---
`scripts/authn-type-surface-ruleset.py` and `scripts/cli-projects-package-surface-ruleset.py` parse any timezone-aware ISO 8601 timestamp and compare in UTC, so `verify-run` no longer exits with `ruleset updated_at is invalid` when the rulesets API returns `2026-09-26T20:16:20.896-04:00` instead of a `Z`-suffixed value. Naive, empty, and malformed values are still rejected; both suites gain the four-shape fixture.
