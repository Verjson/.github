---
date: 2026-08-07
issue: 354
refs: 388
title: Make the changelog migration procedure executable
---

Run changelog migrations from an explicit consumer root using a disposable canonical checkout at one immutable contract SHA, generate executable artifacts, and normalize before enabling validation.

The exact documented sequence now runs in CI against a disposable publishing consumer, including the generated contract suite and release-path dry run.
