---
date: 2026-08-02
issue: 305
title: Document the filename form for issue-less changelog fragments
---

The changelog contract showed one fragment filename and described the issue-less
case in prose only, so readers inferred that the `-issue-` segment tracks the
metadata key and wrote `-id-` names the engine rejects. The contract, the
migration guide, and `NEXT/README.md` now show both filenames side by side and
state that `-issue-` is literal. `scripts/doc-fragment-names.sh` keeps them
honest: it validates every fragment filename example in tracked Markdown against
`CANONICAL_NAME` in `scripts/changelog.py` itself, and fails closed when the
engine cannot be consulted or fails its probes. See #305.

`actions-ci` triggered on an enumeration of paths while `doc-fragment-names.sh` reads every
tracked `*.md` and `doc-tag-pins.sh` every tracked file, so `CLAUDE.md`, `NEXT.md` and
`CHANGELOG/**` were scanned but could not fire the check. That produces the worst failure
shape available: the pull request introducing a bad example passes, and the next unrelated
one fails instead, naming the wrong change and the wrong author. The triggers now include
`**/*.md` and `CHANGELOG/**`, and `scripts/trigger-scope.test.sh` asserts — from the
workflow's own `paths:` list, not a copy of it — that every file each scanner reads is
matched by a trigger, and that the `pull_request` and `push` lists stay identical.
`CHANGELOG/**` is redundant today, since everything under it is markdown; it is kept for a
future non-markdown file there and labelled as such rather than left looking load-bearing.
