---
date: 2026-08-07
issue: 441
title: Reject verdicts produced by terminal-error review passes
---

Treat schema-valid output from a terminal-error review pass as no verdict, so the merge gate fails closed with an inconclusive review instead of publishing fabricated findings.

Verdict validity now follows the selected pass's factual SDK result subtype rather than content-quality heuristics. Successful later passes still recover normally. See ADR 0032.
