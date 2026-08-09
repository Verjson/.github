---
date: 2026-08-08
issue: 659
title: Make generated changelog validation deterministic under pipefail
summary: Feed captured generated contract tests to syntax validation through a file so policy diagnostics cannot be replaced by producer SIGPIPE failures.
---

Generated contract-test validation no longer connects `printf` to an early-exit
validator. Large malformed rendered logs repeatedly retain the intended back-link
diagnostic with `pipefail` enabled.
