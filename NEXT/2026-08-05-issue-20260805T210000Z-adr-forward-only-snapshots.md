---
date: 2026-08-05
id: 20260805T210000Z
refs: 426
title: 'docs(adr): record that the released-snapshot fix is forward-only'
---

ADR 0059 records the two-audience rendering split and, explicitly, that no
re-render of already-released snapshots will be done.

The re-render is *possible* — fragments survive in git history — and that is the
problem. Doing it would establish that a released snapshot is editable when the
reason is good enough, which is the exact guarantee the contract exists to
provide. Being first should cost verjson-ai one 174 KB section, not cost
everyone the immutability property.

Written down because the next person to see that section will propose the
re-render again, reasonably, and the answer should be a decision they can read
rather than an argument they have to lose. `NEXT/README.md` now also tells
authors to write the lead paragraph as the release note, and
`scripts/render-next.sh --as-released` shows what that produces.
