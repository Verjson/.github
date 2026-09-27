---
date: 2026-09-23
issue: 1423
impact: patch
title: Align the cli-projects protected release plan
---

Regenerate the cli-projects organization required workflow to invoke the consumer's
supported `test:release` contract instead of its retired `test:release-v1` alias, keeping
the activation rehearsal and fresh-canary gate aligned with executable consumer behavior.
