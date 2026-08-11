---
date: 2026-08-11
issue: 739
title: Confirm AI review verdicts through one provider-neutral boundary
---

AI review providers now hand one extracted JSON object to a shared canonical
validator. The validator accepts documented structured aliases, normalizes review
locations, enforces the merge-safety invariants, and returns bounded diagnostics for
invalid output without exposing model responses or pull-request diffs. Cross-provider
tests confirm equivalent Claude, OpenAI, and DeepSeek responses produce the same
canonical verdict without another model call.
