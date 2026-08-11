---
date: 2026-08-11
issue: 733
title: Retire stale gate extractors and preserve their live coverage
---

Remove the unregistered hold and re-arm tests that targeted retired workflow steps, and move their surviving terminal-hold and event-rearm cases onto the registered current arm and promotion harnesses.

This keeps caller, permission, concurrency, authority-envelope, receipt, exact-head, hold, unreadable-metadata, terminal-state, and event-rearm invariants attached to executable production surfaces without changing gate behavior. ADRs 0012 and 0079 record the coverage migration.
