---
date: 2026-08-05
issue: 434
title: 'fix(changelog): render an identity as written, not as normalised'
---

A timestamp identity now renders `id:20260805T000000Z` instead of
`id:20260805t000000z`.

`identity` is lower-cased so two spellings of one hexadecimal id cannot become
two entries — that is what makes fragments conflict-free, and it stays. It was
also what reached the page. A timestamp identity is ISO-8601, where `T` and `Z`
are literals, so the normalised form is a mangled timestamp rather than a
quieter one, and issue-less work is exactly the case that uses it.

Rendering now reads the author's spelling from metadata and leaves the
comparison key alone. That the two spellings still collide as one identity is
pinned by its own test, so the cosmetic fix cannot be traded for a duplicate
entry.

This is worth fixing now rather than later because released snapshots are
immutable (ADR 0059): once a release carries a mangled identity, it carries it
permanently.
