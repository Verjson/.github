---
date: 2026-08-30
issue: 1181
impact: patch
title: Make the generated-artifacts fixture independent of the impact grace window
---

Declare the canonical release impact in the generated-artifacts pull-request fixture so the platform test remains deterministic after the bounded migration grace window.
