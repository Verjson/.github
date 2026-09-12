---
date: 2026-09-12
issue: 1323
impact: patch
title: Confirm the terminal-merge credential shape needs no change
---

Design pass on the terminal merge credential (#1323): the canonical
`ai-privileged-merge.yml` already binds the terminal merge step exclusively to a
`merge-app` GitHub App installation token (ADR 0120, hardened by ADR 0166) with no
`ORG_ADMIN_TOKEN`/PAT fallback. A PAT-attributed automation merge reported by an
adopter traced to that repository's caller being pinned to a pre-ADR-0120 revision — a
consumer-side staleness gap, not a canonical-contract defect. See ADR 0120's 2026-09-12
addendum; the adopter's specific remediation is tracked in that (private) repository's
own issue tracker, not named here.
