---
date: 2026-08-26
id: 20260826T212000Z
refs: 1112
impact: patch
title: Bind initial direct review dispatches to the trusted arm
---

Require a unique trusted-arm-owned first workflow attempt before accepting a direct
review receipt, and evaluate recovery against the bare job names emitted by direct runs.
