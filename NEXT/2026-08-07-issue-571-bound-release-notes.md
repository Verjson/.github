---
date: 2026-08-07
issue: 571
title: Bound generated GitHub Release notes
---

Generated Node releases now publish exact changelog snapshots up to 125,000 bytes and conservatively truncate oversized bodies on a line boundary with an immutable link to the full tagged snapshot.

The same bounded file drives release creation and restart reconciliation, including when `RUNNER_TEMP` is unavailable, so an oversized body cannot repeatedly strand an already-published package.
