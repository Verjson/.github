---
date: 2026-08-26
issue: 1114
impact: minor
title: Restore absent secretless compatibility targets
---

Allow verified secretless compatibility artifacts to occupy an initially absent self-package target, then restore that absence after success, failure, or signal without adding a self-dependency pin.

Atomic no-replace placement and cleanup remain inode-bound, while consumer
execution resolves a read-only private package mount populated only from sealed
verified-archive bytes. Deterministic swap/load/restore races cannot substitute
attacker content, multi-lane swaps remain provenance-bound, and existing-target
behavior is unchanged under ADR 0146. The bubblewrap-dependent contracts run on
an explicit hosted Ubuntu 24.04 job whose result remains fail-closed under the
required `shell-tests` aggregate. Positive consumer-fixture failures now report
their exact return code and bounded, credential-scrubbed stderr so a missing or
unusable sandbox dependency is distinguishable without exposing runner secrets.
