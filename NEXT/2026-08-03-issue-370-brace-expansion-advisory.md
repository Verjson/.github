---
date: 2026-08-03
issue: 370
title: Review the new npm-bundled brace-expansion advisory
---

Add a seven-day, advisory-specific exception for the new brace-expansion DoS
bypass in npm's bundled release CLI dependency. The release path is trusted-only,
and the short review window keeps the exception blocking until npm 11 carries
the fixed brace-expansion 5.0.9.
