---
date: 2026-08-10
issue: 723
title: Treat stale promotion retries as no-ops
---

Terminal promotion now validates trusted workflow provenance and exits successfully before receipt verification when an authorized PR head has already been superseded, while preserving every fail-closed check for the current open head.
