---
date: 2026-08-16
issue: 858
impact: patch
title: Distinguish advisory AI checks from approval
---

Blocking, inconclusive, skipped, superseded, and human-only AI review outcomes now complete the authorization check as visibly neutral, while green success is reserved for a persisted exact-head App approval.

GitHub accepts neutral required checks, so ADR 0090's authorized human fallback remains available. Exact-head verification, App approval, and terminal AI-promotion boundaries are unchanged.
