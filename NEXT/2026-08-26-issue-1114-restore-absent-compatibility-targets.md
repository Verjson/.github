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
their exact return code and a fixed allowlisted sandbox-cause category. Raw and
unrecognized consumer stderr is always suppressed, so a missing or unusable
sandbox dependency remains distinguishable without exposing runner secrets.
Confirmed GitHub-hosted compatibility runs acquire bubblewrap only for an
eligible hosted compatibility execution, from signed Ubuntu apt metadata and
without credentials or broad upgrades. Package and executable version floors,
package ownership, root ownership, mode, and execution are verified before use;
self-hosted runners are left untouched. The hosted actions-ci contract mirrors
the production provisioner byte-for-byte and must run it first.
