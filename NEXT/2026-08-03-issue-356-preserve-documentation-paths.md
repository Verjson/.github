---
date: 2026-08-03
issue: 356
title: Preserve documentation paths while validating fragment examples
---

The documented-fragment scanner no longer joins source paths to candidate names
with a space-delimited record it later reparses. Valid examples in tracked
Markdown paths containing spaces now reach the canonical changelog matcher
unchanged, with a committed-path regression fixture covering the case.
