---
date: 2026-08-05
issue: 425
title: 'fix(changelog): reject a title whose quoting is ambiguous'
---

`unquote_scalar` (#420) resolves a genuine quoted scalar and deliberately
leaves alone a title that merely opens and closes with a quote — `"a" and "b"`
is not one scalar, and stripping by position would corrupt it rather than tidy
it. That was the right parser behaviour and the wrong end state: the residue
reaches `CHANGELOG/<version>.md` verbatim, and a released snapshot is immutable,
so nobody can fix it afterwards.

`validate` now fails such a fragment at PR time, while it is still editable, and
the error names both ways out: remove the outer pair, or escape the interior
quotes. A title that resolves to quotes through correct escaping (`'''a'''` →
`'a'`) is still accepted, as is prose that merely starts or ends with a quoted
word — the guard is mutation-tested against both over- and under-broad forms.
