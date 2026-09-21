---
date: 2026-09-21
issue: 1451
title: Wire controller to read-only runner host evidence export
impact: patch
---

The controller and canonical transport now use the pinned `cli-cloud` host
evidence export for baseline, capacity, and post-update observations. Requests
bind reviewed App authority, exact release bytes, fleet, action, and plan; SSH
key material is routed only through a private temporary file. Host observation
fails closed when authority is incomplete and never uses fleet or runner-control
write tokens. Protected environment credential provenance is recorded in
[ADR 0198](../docs/decisions/0198-confine-runner-host-evidence-credentials/README.md).
