---
date: 2026-10-02
id: 202610021317
impact: patch
title: Route private candidate skips through approved runner lanes
---

The private-package pull-request skip notice now follows the repository's configured untrusted runner lane. Its contract test also asserts that the read-only workflow has no private dependency acquisition job.

The generated caller check extracts its validation job without piping into an early-exiting consumer, preserving the repository's shell pipeline safety gate.
