---
date: 2026-08-07
issue: 359
title: Deduplicate AI-review follow-ups before parallel filing
---

Deduplicate identical AI-review follow-ups by their canonical marker hash before starting parallel issue workers, while retaining cross-run lookup and distinct findings.

Regression coverage reproduces the same-run lookup race and verifies stable marker hashing, input ordering, distinct findings, and shell-metacharacter safety.
