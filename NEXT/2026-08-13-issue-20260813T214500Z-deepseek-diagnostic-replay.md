---
date: 2026-08-13
id: 20260813T214500Z
title: Retain redacted DeepSeek diagnostic replays
---

Retain a one-day, exact-head-bound replay when a completed DeepSeek response later fails canonical validation or publication. Bind the replay to the trusted validator revision and retain documented verdict fields while replacing unknown provider values with schema-aware fixed redactions.

The bundle contains projected validated usage, bounds, provenance, and input digests, but never the raw bounded input files. It cannot authorize or cache a review, is never consumed by automation, and incomplete streams or successful reviews upload nothing. ADR 0090 documents the two-checkout offline reproduction and redaction boundary.
