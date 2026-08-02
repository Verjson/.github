---
date: 2026-07-27
id: 20260728T012113Z
title: Pin Node cache workflow dependencies
---

Pinned `actions/checkout` in the cache-restore probe and `actions/setup-node` in
the setup composite to their audited full SHAs, with regression and Renovate
coverage for every Node workflow/setup surface (#152).
