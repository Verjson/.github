---
date: 2026-09-10
issue: 1270
impact: patch
title: Require release context for conventional image dependency files
---

The dependency guard now covers Dockerfile and Containerfile variants and conventional Compose YAML manifests. Actual image-digest changes fail without a new NEXT fragment and pass with one; documentation and backup lookalikes remain outside the boundary. ADR 0038 documents the filename-based scope and canonical consumer adoption requirement.
