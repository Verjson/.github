---
date: 2026-08-09
id: 20260809T170500Z
refs: 659
title: Eliminate captured-value pipeline races in generated changelog checks
---

Generated changelog contract checks now redirect captured workflow values into validators, preventing early-exit consumers from turning intended negative-test diagnostics into `printf: Broken pipe` failures under `pipefail`.

The generator contract test also rejects any recurrence across the analogous snapshot, verification, publication, credential, and first-step checks.
