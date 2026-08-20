---
date: 2026-08-20
issue: 951
impact: patch
title: Test the arm-receipt deletion step's stderr redaction
---

No automated test exercised the `sed` redaction guarding
`ai-privileged-merge.yml`'s receipt-deletion step against a leaked
Authorization header on a failed `gh api --method DELETE` call. A new test
extracts that step's terminal fragment from the shipped workflow and exercises
it against a stub that leaks a header on stderr, asserting the header is
redacted and the deletion failure stays non-fatal.
