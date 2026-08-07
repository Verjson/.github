---
date: 2026-08-07
issue: 520
title: Parameterize generated Node release scope and runtime
---

The canonical Node release generator now accepts validated npm-scope and Node-version options while preserving `@verjson` and Node 24 as backward-compatible defaults.

The same options are available to the generated adopter contract test, which binds both release jobs to the selected values so scaffolders do not need to hand-edit generated workflows.
