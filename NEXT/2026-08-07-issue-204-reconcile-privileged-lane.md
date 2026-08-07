---
date: 2026-08-07
issue: 204
title: Reconcile privileged runner-lane admission and capacity
---

Validate `VERJSON_LANE_PRIVILEGED` alongside the trusted and untrusted lanes so an isolation cutover cannot silently target an inaccessible runner group or a selector with no online capacity.

The scheduled reconciler remains observe-only: it reports drift but does not change runner groups, organization variables, runner infrastructure, or admission policy. ADR 0040 records this repository-local precursor to the external isolation work.
