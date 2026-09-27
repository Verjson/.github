---
date: 2026-09-26
id: 20260926T235900Z
impact: patch
title: Repin the cli-projects required workflow to the hosted tool-cache tree fix (#1599)
---
`cli-projects-package-surface-required.yml` now calls `node-ci-protected.yml@3f8fb4bae1bdf0ced0b821e1b4277523f72a93b9` (merge of #1624) on both of its protected lanes, so the hosted package-surface check for `verjson-cli-projects` no longer inherits the descendant ownership failure #1599 reopened. The ruleset script's reviewed workflow image carries the same pin. Activation under #1423 still requires the consumer's `ci.yml` to be regenerated to this commit first, because admission compares the consumer's default-branch bytes with `CONSUMER_WORKFLOW_SHA256` and fails closed on a mismatch.
