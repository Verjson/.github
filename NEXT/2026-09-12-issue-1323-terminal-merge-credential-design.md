---
date: 2026-09-12
issue: 1323
impact: patch
title: Confirm the terminal-merge credential shape needs no change
---

Design pass on the terminal merge credential (#1323): the canonical
`ai-privileged-merge.yml` already binds the terminal merge step exclusively to a
`merge-app` GitHub App installation token (ADR 0120, hardened by ADR 0166) with no
`ORG_ADMIN_TOKEN`/PAT fallback. The PAT-attributed automation merge observed in
Verjson/verjson-observability is caused by that repository's caller being pinned to a
2026-08-18 revision, five days before ADR 0120 shipped the App-token step — a
consumer-side staleness gap, not a canonical-contract defect. See ADR 0120's
2026-09-12 addendum and the handoff filed at
[verjson-observability#241](https://github.com/Verjson/verjson-observability/issues/241).
