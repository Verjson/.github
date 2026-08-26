---
date: 2026-08-26
issue: 1105
impact: patch
title: Preserve the installed graph in secretless compatibility lanes
---

Replace compatibility-lane package-manager graph re-resolution with a bounded,
provenance-bound package swap so cold offline caches do not require missing
public registry packuments. The lane now rejects archive traversal, links,
special entries, duplicate or surplus roots, size and member-count overflows,
and wrong package identities before any consumer script runs, while restoring
the original installed package on rejection. ADR 0141 records the extraction,
time-of-check/time-of-use, and atomic-swap security boundary.
