---
date: 2026-08-03
issue: 368
title: Release merge-control runners when stability-days defers a PR
---

Give gate preflight the status permission its defer classifier requires, and
make privileged merge runs terminate when Renovate's release-age
status is pending. A late-arriving hold also stops the gate immediately instead
of consuming its polling window, restoring ADR 0023's no-long-running-runner
invariant without weakening failed-check handling.
