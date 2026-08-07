---
date: 2026-08-07
issue: 454
title: Accept block scalar release summaries
summary: >-
  Changelog summaries now accept folded and literal block scalars, so release
  notes can wrap naturally in fragment metadata.
---

Changelog fragment summaries now accept folded (`>`) and literal (`|`) block
scalars, including stripping, clipping, and keeping chomping indicators.
Single-line summaries and the parser behavior for every other metadata field
remain unchanged.
