---
date: 2026-08-22
issue: 1010
title: "test(node-ci): regression test for backslash-containing health commands"
---

Non-blocking AI review follow-up from PR #1008 (the `read -r` fix for
`db-health-cmd`/`cache-health-cmd`): no regression test proved a backslash
survives the tokenization step unaltered. Added one to
`scripts/ci-gate/node-ci-db-service.test.sh`.
