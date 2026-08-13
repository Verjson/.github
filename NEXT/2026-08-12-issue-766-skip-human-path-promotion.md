---
date: 2026-08-12
issue: 766
title: Skip terminal promotion for human-path authorization
---

Terminal promotion retries now exit successfully without dispatching privileged merge
unless the newest exact-head authorization check carries the dedicated App's persisted
AI-authorization marker and the receipt permits `ai-merge`.

Human-path, skipped, blocking, inconclusive, `ai-approve`, and failed-App-approval
outcomes remain terminal no-ops. The marker binds the check ID and reviewed head, while
the privileged merge keeps its independent receipt and exact-head App-approval checks.
ADR 0081 records the corrected event-driven eligibility boundary.
