---
date: 2026-09-18
issue: 1461
impact: patch
title: See a multi-line awk consumer on the read end of a pipe
---

The `pipefail-sigpipe` guard now buffers a quoted argument written across real
newlines, so an `awk` program spanning several lines is scanned as the one
pipeline it is, and its `exit` is read from inside the quoted program rather
than from "anything after `awk` with no `|` in between". Two live sites the
guard could not see are converted to the here-string form it already prescribes.

Both sites were latent rather than active, and that is the reason to fix them
rather than to leave them. In `changelog-caller-contract.test.sh` the piped
value is ~21,437 bytes — under the 64 KiB pipe buffer — so `printf` finishes
writing before `awk` exits and the pipeline returns 0 today. It arms itself the
moment the generated `release-node` workflow crosses 64 KiB. A correctness
argument that rests on a property of today's input rather than of the code is
exactly the class #1445 exists to reject; the second site, in
`require-secrets.test.sh`, is the same shape with a smaller input.

The old `awk` arm required no `|` between `awk` and `exit`, which excluded
precisely the programs long enough to need joining — the first site matches
`/^ *run: \|$/`. The arm is now bound to the literal quoted program attached to
`awk`, crossing a `-v name="$value"` assignment but not a program supplied from
a variable or a `-f` file. Two remaining ceilings are stated in the guard rather
than implied by its green run: the joiner models quotes but not here-document
delimiters, so a here-doc inside a capture can merge two neighbouring sites into
one reported record, and a literal `exit` in an `END` block still reads as an
offender even though `END` runs only after the input is read to EOF.
