---
date: 2026-07-28
id: 20260728T012114Z
title: Disable setup-node automatic cache discovery
---

Disabled setup-node's package-manager auto-cache path in the reusable Node
workflows and composite action so caching is controlled only by the explicit
cache input and matching lockfile contract (#152).
