---
date: 2026-08-07
issue: 569
title: Authenticate generated release verification hooks
---

Generated Node release callers now expose the private-package read credential to the verification-hook/default-suite step, allowing supported hooks to query private package metadata before a release mutates history.

The credential remains step-scoped, absent from pull-request workflows and unrelated release steps, unblocking `Verjson/verjson-object-storage#45` and `Verjson/verjson-object-storage#56`.
