---
date: 2026-08-24
issue: 1054
title: Correct AI-review labels to a separate pull-request caller
---

Replace the disproved `issues:labeled` trigger with a distinct protected
`pull_request_target:labeled` caller that reuses the canonical authorization arm and
binds its exact caller source, delivery actor, pull request, and immutable head.
