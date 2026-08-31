---
date: 2026-08-31
issue: 1214
impact: patch
title: Pin the ADR index sort to the C collation
---

`scripts/gen-adr-index.sh` sorted the ADR directory list twice under the ambient
locale, so the ordering of the generated table depended on `LC_ALL`/`LC_COLLATE`
in the environment that happened to run it. Both sorts are now pinned to
`LC_ALL=C`, and `scripts/ci-gate/gen-adr-index.test.sh` regenerates the index
under a UTF-8 collation and asserts `--check` still passes.

This is hardening, not a reproduced defect: with the current corpus the two
collations agree. The `NNNN-` prefix is zero-padded, so the numeric field
dominates every comparison, and `validate_unique_numbers` rejects duplicate
numbers before slug order can decide anything. The ordering is therefore only
reachable through slugs sharing a number, which the generator already refuses.
Pinning the collation makes that independence explicit rather than incidental,
so a future change to the naming scheme cannot silently make CI's `--check`
disagree with a contributor's locally generated index.
