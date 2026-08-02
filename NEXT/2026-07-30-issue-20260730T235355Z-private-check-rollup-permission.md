---
date: 2026-07-30
id: 20260730T235355Z
title: Allow read-only private check rollups
---

Grant the unprivileged, `ORG_ADMIN_TOKEN`-free merge gate `checks: read` so GitHub permits `statusCheckRollup` queries in private consumer repositories. Write access remains absent, `actions: write` stays isolated in the metadata-only dispatcher, and `ORG_ADMIN_TOKEN` never enters PR-controlled execution. See #240 and ADR 0037.
