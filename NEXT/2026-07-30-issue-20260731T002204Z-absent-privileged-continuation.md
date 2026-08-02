---
date: 2026-07-30
id: 20260731T002204Z
title: Keep validation green without a privileged continuation
---

Treat an absent repository-local privileged merge workflow as a successful
manual-merge fallback while keeping workflow-enumeration failures fail-closed.
This restores the consumer boundary recorded by ADR 0036 without expanding
`actions: write` or exposing `ORG_ADMIN_TOKEN` (#247).
