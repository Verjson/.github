---
date: 2026-09-23
issue: 1486
title: Pin required-check audit test fixtures to the audited contract
impact: patch
---

Build required-check audit fixtures from the committed contract pin so uncommitted generator edits cannot create false byte-drift failures.

The audit stub and its fixture generator now consume the same immutable source, while the existing handwritten-drift cases continue to prove that real consumer changes fail closed.
