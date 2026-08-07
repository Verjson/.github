---
date: 2026-08-05
issue: 437
title: Generate shared artifact callers and ADR index tooling
---

`gen-changelog-caller.sh` can now emit a `generated-artifacts.yml` caller while
preserving the existing changelog-only caller. Repositories opting into ADR
index validation can acquire `gen-adr-index.sh` from the same immutable pin and
generate a caller that enables both checks; the generated contract test verifies
that pinned script before accepting `adr-index: true`.

The previous guidance in this fragment told adopters to stay on
`changelog-validate.yml` because the generator and its conformance test could
not represent the shared workflow. The fix closes that gap without forcing a
migration: repositories needing only changelog validation can keep the original
generated caller.
