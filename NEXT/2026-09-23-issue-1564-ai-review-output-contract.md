---
date: 2026-09-23
issue: 1564
title: Harden AI review output instructions and diagnostics
impact: patch
---

- Require review providers to return only the canonical JSON verdict keys and fold follow-up metadata into the supported `note` field.
- Add incident fixtures proving malformed follow-up objects and non-JSON fallback responses remain fail-closed with actionable, content-free diagnostics.
