---
date: 2026-08-05
issue: 398
title: Pass the rendered changelog to the contract test as a file, not an argument
---

The generated contract test handed the rendered `NEXT/` to `python3` through an
environment string. A single argv or environment string is capped at
`MAX_ARG_STRLEN` — a fixed 128 KiB, not the 2 MiB `ARG_MAX` that a size check
reads — so once an adopter's unreleased log crossed it, the suite died at the
render assertion:

```
ok - contract scripts are executable
scripts/changelog-contract.test.sh: line 121: /usr/bin/python3: Argument list too long
```

Exit 126, naming neither the changelog nor the fragment count.

Nothing bounds an unreleased `NEXT/`. Fragments are per-change and never batched,
and only a release consumes them, so the ceiling is a function of release cadence
rather than of anything an adopter does wrong: `Verjson/verjson-ai` reached
131,936 bytes in one delivery run (`Verjson/verjson-ai#162`) and went red on
`main`, blocking every pull request. It could not release its way out either —
a release drains `NEXT/`, but the release workflow runs this suite first.

`scripts/gen-changelog-caller.sh` now writes the rendered log to the suite's
scratch directory and passes the path, which removes the ceiling instead of
raising it. `scripts/changelog.py` was audited for the same shape and has none;
it passes only short arguments to `git`.

`scripts/ci-gate/changelog-caller-contract.test.sh` builds a fixture adopter
whose `NEXT/` renders to ~160 KB, and asserts that size exceeds 128 KiB before
asserting the emitted suite survives it — without that first assertion the case
would pass for the wrong reason if the fixture ever shrank. Verified red against
the unfixed generator, reproducing the reported message and exit code, then green.

Adopters take the fix by regenerating at a contract commit containing it. There
is no local patch: editing the generated test fails the pin check, as intended.
