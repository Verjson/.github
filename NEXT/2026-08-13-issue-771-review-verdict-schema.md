---
date: 2026-08-13
issue: 771
title: Align the AI review prompt with the canonical verdict schema
---

The provider-neutral AI review prompt now requests canonical `review_first[].why`, with contract coverage proving provider variants normalize to that shape before rendered review comments consume it.

Backward-compatible `reason` and `rationale` aliases remain accepted for historical provider output and model variance.
