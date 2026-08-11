---
date: 2026-08-10
issue: 700
title: Keep generated release callers Renovate-inert
---

Render generated Node-version fields as literal GitHub expressions so Renovate cannot desynchronize release callers from their generated contract tests while Actions still receives the selected Node version.

The generated contract now rejects Node fields that drift back to Renovate-visible YAML literals, preserving the invariant for every adopter without repository-local Renovate policy.
