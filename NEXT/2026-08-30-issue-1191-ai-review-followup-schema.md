---
date: 2026-08-30
issue: 1191
title: Accept canonical AI-review follow-up aliases
impact: patch
---

Normalize the bounded `suggestion` and `recommendation` provider aliases into the
canonical follow-up `note` field. Preserve fail-closed rejection of conflicting aliases,
unknown response fields, and injected nested payloads, with replay coverage for both
captured DeepSeek response shapes from run 33293783983.
