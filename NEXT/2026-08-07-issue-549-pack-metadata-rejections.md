---
date: 2026-08-07
issue: 549
title: Exercise malformed npm pack metadata rejections
---

Restart-safe Node release tests now prove that ambiguous multi-package pack output and a packed version differing from the dispatched release both fail before registry publication or reconciliation.

These behavioral fixtures cover the package-identity validation branches that protect the immutable publication decision.
