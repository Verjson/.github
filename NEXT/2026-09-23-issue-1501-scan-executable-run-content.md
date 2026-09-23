---
date: 2026-09-23
issue: 1501
impact: patch
title: Scan executable authorization steps for runner-held waits
---

The event-driven authorization contract now parses workflow `run:` blocks and ignores shell comments before rejecting runner-held waiting constructs. Paired mutation controls prove a real executable `sleep` remains rejected while comments may name `sleep`, `MERGE_PROBE`, and `ci-wait` without making the governing contract itself fail.
