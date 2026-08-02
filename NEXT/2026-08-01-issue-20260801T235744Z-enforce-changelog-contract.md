---
date: 2026-08-01
id: 20260801T235744Z
title: Validate this repository's own changelog fragments in CI
---

This repository defines the canonical changelog contract but never ran the
validator over its own `NEXT/` (#289). `actions-ci.yml` exercised the tooling —
the renderer, its edge cases, and `changelog.test.py` — while the fragments those
tools exist to govern went unchecked, so the contract's own repository was the one
place it was not enforced.

`python3 scripts/changelog.py validate` now runs in CI. The pre-#249 fragment from
e18650b is migrated to the canonical identity `2026-07-20-issue-80-actionlint-workflow-linter.md`
with `date`/`issue`/`title` metadata, its H1 folded into the body.

The step passes `--allow-legacy-next` because 88 further pre-#249 fragments still
carry legacy filenames; strict validation would fail `main` today. `validate` stops
at its first error, which is why the finding read as a single bad fragment. The
switch is removed once those are migrated, and until then it enforces the contract
on every canonical fragment, including new ones.
