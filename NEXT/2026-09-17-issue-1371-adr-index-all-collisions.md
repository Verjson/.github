---
date: 2026-09-17
issue: 1371
title: Name every colliding ADR number in one gen-adr-index run
impact: patch
---

`validate_unique_numbers()` aborted on the first duplicate ADR number it found.
With a three-way collision that reports two of the three directories, so whoever
renames the pair the error named hits the same error again on a directory
nothing had mentioned. Independent collisions behaved the same way: the second
pair stayed invisible until the first was resolved.

The validation now walks the whole decisions directory, records every colliding
number with all of its directories, and reports them together before returning
non-zero. The reporting loop only runs when there is something to report, so the
happy path still performs exactly the two `LC_ALL=C` sorts the collation test
pins.

This is what `Verjson/verjson-cli-cloud#516` is waiting on: its generated
`scripts/gen-adr-index.sh` is emitted from a pinned contract SHA, so the fix
reaches that adopter only once a contract SHA containing this commit exists and
the adopter re-pins to it.
