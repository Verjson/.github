---
date: 2026-08-07
title: Enforce an immutable contract_ref before changelog-validate checks anything out
issue: 412
---

`changelog-validate.yml` described `contract_ref` as an "Immutable Verjson/.github commit"
and then handed it straight to `actions/checkout`'s `ref:`, which accepts **any** ref of this
repository. The job executes `python3 .changelog-contract/scripts/changelog.py` from the
result, so that input decided what code ran. `required: true` guaranteed only that it was
present. Around 90 repositories call this workflow.

- This repository is **public**, so `refs/pull/<n>/merge` is reachable by anyone who can open
  a pull request against it — a caller passing that ref would run unreviewed Python on the
  Verjson lane.
- A typo'd branch name validated against a non-canonical contract and looked like a pass,
  which is the exact failure ADR 0038's pinning exists to prevent.

The guard is the one `generated-artifacts.yml` already carried (#407): exactly 40 lower-case
hex, rejected **before either checkout**, so an invalid call fetches nothing. Ordering is
load-bearing — a guard placed after the checkout has already fetched the code it was meant to
vet — so the test asserts it by position and by mutation, not just by presence. Per #312 a
prefix is not a pin: an abbreviated SHA is ambiguous by construction, since git resolves it
against whatever objects exist at fetch time. The predicate is anchored at both ends, and 39
characters, over-long, upper-case, whitespace-padded, empty and `refs/heads/<sha>` are all
rejected. A test pins the predicate to `generated-artifacts.yml`'s character for character so
the two cannot disagree about what counts as a pin.

Also found in review and fixed here: both checkouts now set `persist-credentials: false`,
which the sibling workflow already did and this one did not. The contract engine is Python
from a *separate* checkout running in the same workspace, so a token left in the consumer's
`.git/config` sat inside that engine's blast radius. Nothing in this workflow pushes.

`scripts/ci-gate/changelog-validate-pin.test.sh` is wired into `actions-ci.yml` in the same
commit — an unwired test does not run, which is the gap that once left `hold.test.sh` dormant.
Rationale is in the [2026-08-07 amendment to ADR 0038](docs/decisions/0038-canonical-changelog-contract/README.md).
