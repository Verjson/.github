---
date: 2026-09-12
issue: 1333
title: Bound deployment transport replay inventory requests
---

Bound the GitHub workflow-run replay inventory to 40 list requests per probe, shared by the complete baseline and post-dispatch reconciliation. A trusted history that cannot fit the remaining budget fails closed before dispatch, preventing paginated polling from amplifying provider rate-limit load.
