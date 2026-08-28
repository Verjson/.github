---
date: 2026-08-28
issue: 1145
impact: patch
title: Prove sealed descriptors close before consumer execution
---

Exercise the namespace-bound npm consumer through `/proc/self/fd` and require that none
of the sealed compatibility-input descriptors survive bubblewrap setup into consumer
execution.
