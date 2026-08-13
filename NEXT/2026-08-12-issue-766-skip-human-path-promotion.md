---
date: 2026-08-12
issue: 766
title: Skip terminal promotion for human-path authorization
---

Terminal promotion retries and post-merge reconciliation now exit successfully without
privileged processing unless the newest exact-head authorization check carries the
dedicated App's persisted `ai-merge` marker.

Human-path, skipped, blocking, inconclusive, `ai-approve`, and failed-App-approval
outcomes remain terminal no-ops. The marker binds the check ID, reviewed head, and
receipt-derived authority, while privileged merge and post-merge follow-up processing
keep their independent exact-head evidence checks. ADR 0081 records the corrected
event-driven eligibility boundary. For approval markers minted immediately before this
rollout, post-merge reconciliation recovers authority only from the originating trusted
run's `dispatch-merge` job: success admits the legacy `ai-merge` path and skipped stays a
non-merging no-op.
