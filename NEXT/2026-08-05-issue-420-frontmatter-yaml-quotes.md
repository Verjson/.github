---
date: 2026-08-05
issue: 420
title: 'Resolve YAML quoting in changelog front matter'
---

Front matter is parsed line-wise with `str.partition(":")`, and the right-hand
side was stored verbatim. YAML *requires* a quoted scalar wherever a value
contains `: `, which is the shape of every conventional-commit title, so
`title: 'Fix: thing'` rendered as `## 'Fix: thing'`. Reported against
`Verjson/verjson-ai` `CHANGELOG/v0.11.0.md`, where every heading is quoted.

The incentive was inverted: the only spelling that rendered correctly was the
one a real YAML parser rejects, so checking that a fragment parses was what
produced the broken output. `unquote_scalar` now resolves single- and
double-quoted scalars for every key, not just `title` — `issue: '249'` is
equally valid YAML and used to reach `int()` with its quotes attached.

Quotes are resolved by structure rather than by position. A title that merely
opens and closes with a quote character (`"a" and "b"`, `'a' or 'b'`) is not a
quoted scalar and is left untouched; stripping it would corrupt a heading
rather than tidy one. YAML's escapes are honoured, so `'It''s fixed'` and
`"Say \"go\" once"` survive intact.

This changes rendered output for fragments that were already quoted, so
repositories pick it up when they bump their pinned contract SHA. Released
snapshots are immutable (ADR 0038), so `v0.11.0` keeps its quoted headings and
the correction appears in verjson-ai's next release.

Note that this fixes only the quoting half of the report. The same snapshot is
174 KB for 62 entries because one `render()` serves both the unreleased running
log and the released snapshot, so engineering rationale ships as release notes.
That is a contract change and needs its own decision record.
