---
date: 2026-09-11
issue: 1297
impact: patch
title: Record operational alerting expectations for inherited secret context
---

Amend ADR 0171 with the operational control the AI-review follow-up asked for:
inherited secret delivery is monitored at runtime for access patterns the reviewed
workflows cannot legitimately produce, and any such observation is an incident that
pauses dispatch. No transport, policy or pin decision changes.
