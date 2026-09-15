---
date: 2026-09-15
issue: 1360
impact: minor
title: Release actions can derive a blank version
---

Generated Release workflows now accept a blank version and resolve the selected
stream through the canonical read-only release plan. The workflow summary shows
the previous release, bump rationale, selected fragments, assembled notes, and
source commit before the existing verify, snapshot, and publish stages run.
