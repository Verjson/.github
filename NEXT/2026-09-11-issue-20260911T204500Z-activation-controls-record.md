---
date: 2026-09-11
id: 20260911T204500Z
refs: 1303
impact: minor
title: Record verified App-binding activation and fresh PR-head controls
---

Record in ADR 0173 the 2026-09-10 activation of the reviewed producer App bindings on
both organization rulesets, with exact preimage/postimage verification and unchanged
non-selected policy, and the 2026-09-11 post-activation controls: every fresh check
run for all four contexts produced by the bound App, fresh passes on merged heads for
all four contexts, and fresh failures blocking merge for both rule objects. The
residual — no natural failure yet for two contexts sharing the proven rule, and no
staged wrong-app control — is recorded explicitly instead of manufactured.
