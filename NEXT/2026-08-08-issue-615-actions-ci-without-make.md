---
date: 2026-08-08
issue: 615
title: Remove undeclared make dependency from actions-ci
---

The actions-ci manifest now invokes the canonical renderer and ADR-index scripts
directly, while the Makefile remains a developer convenience surface. Its portability
contract validates recipes statically, so routed minimal runners no longer need a
system `make` binary.
