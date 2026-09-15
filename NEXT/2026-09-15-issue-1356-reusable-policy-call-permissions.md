---
date: 2026-09-15
issue: 1356
title: Fix nested App-key policy workflow startup
---

Remove unsupported job-level `permissions` mappings from jobs that call the nested
App-key environment workflow. The workflow-level `actions: read` and `contents: read`
boundary remains authoritative, while GitHub can now plan the reusable workflow and
create its credentialless policy job.
