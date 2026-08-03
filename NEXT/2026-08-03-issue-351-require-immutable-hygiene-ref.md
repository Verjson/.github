---
date: 2026-08-03
issue: 351
title: Require immutable repository-hygiene policy refs
---

The reusable repository-hygiene workflow now rejects branches, tags, abbreviated
hashes, and malformed refs before checkout. A full commit SHA must also remain
reachable from `main`, preserving the existing reviewed-and-merged boundary;
focused behavioral coverage exercises mutable, unmerged, and merged refs.
