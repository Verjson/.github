---
date: 2026-08-07
title: Accept a NEXT/-relative selected fragment in the canonical release
issue: 328
---

`changelog-release.yml` forwards each selected entry to the engine unchanged, and release
callers naturally supply the repository-relative path they were given —
`NEXT/2026-08-02-issue-1-initialize-customer-lifecycle.md`. `release` indexed selection by
basename only, so that value was rejected with:

```text
selected fragment does not exist: NEXT/2026-08-02-issue-1-initialize-customer-lifecycle.md
```

which reads as a missing fragment rather than a path-shape mismatch. It cost a real release
dry-run to diagnose (`verjson-customer-lifecycle#4`, failed run 30770166825).

Both spellings are now accepted — bare basename and `NEXT/<file>` — and the error names the
accepted forms when neither matches.

**Traversal is refused rather than normalised away.** Taking the basename unconditionally would
make `../../elsewhere/<name>.md` select the fragment that happens to share its name, and a
value pointing outside the unreleased directory is a caller bug worth surfacing. Absolute
paths, `..` components, a foreign parent directory, a nested `NEXT/sub/`, and the empty string
are each refused with a distinct message, and a refused selection writes no snapshot.

The pre-existing "does not exist" error survives for its original cause, now unambiguously: it
means the fragment is absent, not that the path was spelled differently.

`UNRELEASED_DIR` is named once and used by both the directory scan and these diagnostics, so
the message and the directory it describes cannot drift.

Red-first: against the unfixed engine the `NEXT/`-relative case errors and all six refusal
cases fail, while the bare-basename and genuinely-missing cases pass either way — they are the
guard-rails, not the evidence.
