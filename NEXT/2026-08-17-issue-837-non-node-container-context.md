---
date: 2026-08-17
issue: 837
impact: patch
title: Supply the container dependency context for non-Node adopters
---

Create an empty, credential-free `verjson_node_modules` named build context when
private Node packages are absent, allowing non-Node repositories to complete first
adoption without adding a package graph.

Private-package consumers retain exact cache restoration, lock-digest validation,
credential isolation, and cleanup before the same named context reaches Docker.
