---
date: 2026-07-28
id: 20260729T040917Z
title: Composite cache guard warning
---

- `setup-verjson-node` README: documented that the composite has no
  `cache-max-mb` end-of-job cache-size guard (unlike `node-ci.yml` /
  `node-release.yml`) — bespoke callers enabling `cache: 'true'` own their
  own guard. Warning added directly in the usage block. (#169)
