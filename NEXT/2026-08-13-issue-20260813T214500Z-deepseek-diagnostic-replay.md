---
date: 2026-08-13
id: 20260813T214500Z
title: Retain redacted DeepSeek diagnostic replays
---

Retain a one-day, exact-head-bound replay when a completed DeepSeek response later fails canonical validation or publication, containing only the reconstructed verdict, projected validated usage, bounds, provenance, and input digests.

The bundle cannot authorize or cache a review, is never consumed by automation, and incomplete streams or successful reviews upload nothing. ADR 0090 documents the offline reproduction and redaction boundary.
