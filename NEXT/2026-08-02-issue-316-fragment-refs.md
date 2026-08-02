---
date: 2026-08-02
issue: 316
refs: 317
title: Let a fragment link an issue it does not own, and define snapshot repair
---

Fragments may now carry an optional `refs:` list of issue numbers they link but
do not own. Identity stays unique — that is what makes fragments conflict-free —
so only one entry per issue carries `issue:`; before this, every other entry for
that issue silently lost its `#n` release back-link, with no validation error.
`refs` is additive: a fragment without it renders byte-identically to before, so
no consumer is forced to re-pin.

`docs/changelog/README.md` also now defines how to repair a malformed released
snapshot. `check-pr` rejects modifying an existing snapshot, not just adding one,
so a migration mistake was permanent by construction. It is a pull-request guard
rather than a filesystem lock, so the path existed but was undocumented.
