---
date: 2026-08-04
issue: 387
title: Remove branch-selectable runner admission dispatch
---

Remove `workflow_dispatch` from runner admission reconciliation so a selected
branch cannot control code that receives `ORG_ADMIN_TOKEN`. Scheduled runs bind
checkout to their immutable default-branch `github.sha`; shared semantic contract
coverage rejects alternate triggers, checkout sources, execution surfaces, bare
sequence steps, and quoted executable keys. ADR 0033 records the boundary and the
residual #261/#265 organization-secret work.
