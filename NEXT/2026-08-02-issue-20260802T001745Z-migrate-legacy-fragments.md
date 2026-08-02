---
date: 2026-08-02
id: 20260802T001745Z
title: Migrate the pre-contract fragments and drop the legacy switch
---

All 88 pre-#249 fragments now carry canonical identities and metadata, so
`validate` and `render-next.sh` run strict — `--allow-legacy-next` is gone from
both call sites and this repository finally meets the contract it defines (#289).

Identity was assigned conservatively. Where the fragment's originating commit
subject named an issue that is genuinely an issue in this repository and not
already claimed, that number is the identity: 25 of 88. The other 63 take a UTC
timestamp `id` derived from their add-commit. Prose references were left
untouched, so attribution is unchanged; identity is collision-resistant
ownership, not attribution, and guessing an owner from body prose would have
misattributed history at scale to save nothing.

The flag remains in `changelog.py` for consumers still mid-migration under
Verjson/.github#286, and `--legacy-dir` is untouched.

One user-visible consequence: `0000-archive.md` is no longer rendered. Strict
mode skips it by name rather than sorting it last, because it is pre-contract
history and not an unreleased fragment. The file is unchanged; read it directly.
`scripts/ci-gate/render-next.test.sh` now pins that exclusion.
