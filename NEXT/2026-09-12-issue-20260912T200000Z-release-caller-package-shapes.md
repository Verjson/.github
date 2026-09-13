---
date: 2026-09-12
id: 20260912T200000Z
impact: patch
title: validate package selections for every release caller
summary: The generated release contract now derives package selections for Node, artifact, and snapshot callers independently, so sibling release workflows are validated against their own version stamping behavior.
---

Keep release caller validation aligned with each generated release mode and its selected package directories.
