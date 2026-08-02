---
date: 2026-08-02
id: 20260802T161500Z
title: Sync the Active Issues list after the changelog-contract audit
---

The Active Issues list loads into every session, so a stale entry costs context in each one
and misreports the state of the work. #251, #276 and #293 closed earlier in the batch, and
#304, #305 and #308 closed in this audit — six entries describing finished work.

Added #312 (`ref_is_immutable` accepts abbreviated SHAs, untested), #316 (the contract
cannot express N entries closing one issue) and #317 (hand-authored snapshots diverge from
the shape `release` generates), which were filed during the migration sweep and were not
listed.
