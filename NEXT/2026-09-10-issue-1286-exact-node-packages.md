---
date: 2026-09-10
issue: 1286
impact: minor
title: Select exact nested Node release packages
---

Add repeatable `--only-package-dir` selection to generated release callers and their contract tests. Nested-only releases stamp and publish only the selected packages; existing root defaults and additive `--package-dir` callers retain their behavior. Reject mixed selection modes, empty or duplicate paths, and paths outside the normalized repository-relative contract.
