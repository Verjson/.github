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

Review of the first revision found that reaching the program across a
double-quoted `-v name="$value"` but not a single-quoted `-v FS='|'` was a
coverage *regression* against the arm being replaced, which matched both. No
tracked script was dropped by it, which is exactly why it needed a fixture
rather than a sweep: the bridge now crosses either quoting and each spelling is
pinned. The cost is stated rather than hidden — crossing quoted values also lets
the arm walk past a program to a later quoted string, so
`awk '{print}' || fail 'the job did exit early'` reads as an offender although
nothing truncates. That is the safe direction, and it surfaces only inside the
already-excluded generator today.

An offending record is now reported at the line the match starts on rather than
the line the record starts on. Merged records are not confined to the excluded
generator — `complete-authorization.test.sh` buffers 129-387 and
`actions-ci-groups.test.sh` 85-321 — and an offender planted at
`actions-ci-groups.test.sh:201` was previously reported at `:85`, 116 lines away
from itself. The offset map that fixes that is emitted by the joiner and read
only for records `grep` has already kept.

A second review round, scoped to the offset map this fix added, attacked the map under
multi-byte input, at both record ends, and with a missing offset, and found no path that
drops a site: both degradations fall back to the record's first line. A sweep of all 159
tracked scripts with the exclusion arm removed put the widened bridge's cost at exactly
one new site and zero sites lost, so the widening is a pure superset of what the scan saw
before.

Two reporting defects closed with it. The self-referential span in the comment block was
dropped rather than corrected: a hand-maintained line range inside the file it describes
rots on the next comment edit above it, including the edit that fixes it, and the five
external spans make the point without a number that moves. And the report now prints only
the line its number names — the resolver already walks the offset map, so it carries the
successor offset and slices the record — where before it printed the whole joined record
and buried the offending line under thousands of characters of its continuation.
