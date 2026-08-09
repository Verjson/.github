---
date: 2026-08-09
issue: 627
title: Add immutable stable container promotion
summary: Adds a dispatch-only, fail-closed stable container release contract that promotes verified candidate digests without rebuilding or deploying.
---

Stable container releases now promote an immutable verified candidate through an
explicit dispatch, preserving exact digests and producing a deployment-ready manifest.
