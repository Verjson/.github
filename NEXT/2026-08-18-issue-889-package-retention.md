---
date: 2026-08-18
issue: 889
impact: patch
title: Retain the three newest numbered package releases
---
Canonical Node and container releases now delete stable numbered package versions older than the newest three and remove only aged, unreachable untagged container versions after publication succeeds.

Cleanup serializes releases, revalidates immediately before each deletion, protects every package version reachable from a retained OCI graph regardless of tag class, fails closed on ambiguous metadata, and cannot retroactively invalidate a successful publication. ADR 0108 records the intentionally limited install and rollback window.
