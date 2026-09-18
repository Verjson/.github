---
date: 2026-09-18
issue: 1473
title: Require the conformance reset to name every variable the loop assigns
impact: patch
---

The structural assertion added with #1448 pinned the per-repository reset's *position*
but not its *membership*. Deleting `metadata default_branch visibility_type has_secret`
from the reset list in `scripts/privileged-merge-conformance.sh` passed the entire suite
green — exit 0, zero failures — and that is precisely #1448's own bug class: a variable
assigned in the fleet loop and forgotten from the reset. The check could not have caught
the defect it was added for. Re-confirmed against the merged code at `89f11f6` before
this change, not only against the branch the finding was raised on.

The assertion now walks the loop body for every assignment form the script actually
uses — `=`, `mapfile -t`, `read` behind an `IFS=` command prefix, and `printf -v` — and
requires the reset to name all of them. Each pattern is anchored on leading whitespace,
so neither `::error title=…` annotation text nor the embedded `awk` program, whose lines
begin with `$0` or a bare word, can forge a name. It runs in both directions: a forgotten
assignment reddens, and so does a dead reset entry.

The carry-over exemptions are `repositories_scanned`, `consumers`, `failures`, and `IFS`,
established by reading the script rather than inherited from the review. The first three
are fleet totals reported after the loop closes; `IFS` is a command-prefix assignment
scoped to the `read` it precedes and is never loop state. `visibility` and
`selected_repositories` need no exemption at all — they are assigned before the loop and
never inside it — and the check asserts that stays true rather than quietly exempting
them. Resetting any carried value now reddens too, so the exemption list cannot grow into
a loophole.

Three smaller findings close alongside it:

- The mutated-copy fixture asserted only that the copy differed and contained the widened
  pattern, not that the widening was **confined**. It now requires exactly one replaced
  line, which is what makes testing against a mutated copy defensible rather than merely
  plausible.
- `AUDIT_SCRIPT` is assigned at top level beside `audit=` instead of being defaulted at
  the call site, so an inherited environment value is discarded. The seam already failed
  closed — `AUDIT_SCRIPT=/bin/true` produced 39 failures, not a silent green — so this is
  hygiene rather than a hole.
- The loop-exit scan now strips whole-line comments before looking for `continue`/`break`,
  and anchors the reset on being the loop's only top-level `unset` rather than the first
  line that starts with one. Prose cannot redden it, and an unrelated `unset` cannot
  satisfy it vacuously.

| Mutation | Assertion that fires |
| --- | --- |
| reset list loses `metadata default_branch visibility_type has_secret` | `assigned per repository but never reset: ['default_branch', 'has_secret', 'metadata', 'visibility_type']` |
| a new loop variable is added and forgotten | `assigned per repository but never reset: ['newly_added_state']` |
| reset list gains a name the loop never assigns | `reset but never assigned in the loop: ['never_assigned_anywhere']` |
| reset clears a fleet accumulator | `the reset clears a value the fleet audit must carry: {'consumers'}` |
| reset returned to the bottom of the loop | `early exits precede the reset:` naming all five |

`Verjson/.github#1471` would widen the shipped extractor so the 40-hex guard is reachable
from a real fixture, which would retire the mutated-copy fixture and with it the
confinement assertion above. That is a deliberate sequencing choice recorded here, not an
oversight: the assertion is cheap and honest today, and removing it is #1471's job.
