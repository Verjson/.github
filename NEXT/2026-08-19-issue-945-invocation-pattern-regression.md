---
date: 2026-08-19
issue: 945
impact: patch
title: Fix a merge-gate CI regression introduced by #945's own merge
---

#945 merged with a red `merge-gate` CI group: multi-line env-var-prefixed invocations
of `verify-arm-receipt.sh` (`FOO="..." \` on one line, `bash .../verify-arm-receipt.sh`
on the next) broke `event-driven-authorization.test.py`'s single-line invocation
pattern check, and `native-automerge.test.sh`'s extracted `promote.sh` fixture hit an
unbound `$RUNNER_TEMP` under `set -u` since the harness never exported it (never
needed before this change).

Both workflows now `export ARM_RECEIPT_ARTIFACT_ID_FILE=...` on its own line before
the plain, single-line `bash .../verify-arm-receipt.sh` invocation, restoring the
expected shape. `native-automerge.test.sh` now exports a scratch `RUNNER_TEMP`,
matching real Actions runtime behavior.

Refs #945.
