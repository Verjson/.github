---
date: 2026-08-05
issue: 436
title: 'fix(changelog): the generated contract test reads quoted titles'
---

The adopter contract test now unquotes front-matter scalars the way the engine
does, so a fragment titled `'fix(x): the thing'` stops being reported as a
missing title.

YAML requires a quoted scalar wherever a value contains `: `, which is every
conventional-commit title, so the check fired on the correct spelling and stayed
quiet on the incorrect one. #425 made that worse rather than better: the engine
now explicitly blesses a well-formed quoted scalar that the conformance test
rejected.

The unquoting is reimplemented in the emitted test rather than imported, because
that file exists to check the engine's output and must not borrow the engine's
reading of the input. The generator's own fixture now carries a quoted
conventional-commit title, so every existing case exercises the real spelling —
an unquoted fixture is what let this ship.

Found while preparing the fleet pin bump: regenerating this artifact across
adopters would have shipped the trap rather than fixed it.
