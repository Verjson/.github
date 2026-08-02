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
