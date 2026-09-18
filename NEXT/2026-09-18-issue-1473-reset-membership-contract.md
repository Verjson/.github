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

The assertion now walks the loop body for every assignment form bash offers, not the
handful the script happens to use today, and requires the reset to name all of them. The
first attempt anchored four regexes on leading whitespace, which silently missed an
assignment sitting behind a `case` arm label or a `[ … ] &&` short-circuit — exactly how
`has_secret` is written at `scripts/privileged-merge-conformance.sh:483`, `:485`, and
`:488`. It was collected only incidentally, via the unrelated `has_secret=false` on
`:481`, so a rewrite that dropped that line would have re-opened the hole the check
exists to close.

The collector is now a small quote-aware tokenizer: it splits each line into command
segments on unquoted `&&`, `||`, and `;`, splits each segment into words honoring quotes,
`$(…)`, and `${…}`, strips lead-ins (control keywords, a bare `!`, test brackets, `case`
arm labels), consumes stacked `NAME=value` command prefixes, and then reads the command
word. That covers `=`, `+=`, indexed and associative element assignment, `declare`,
`typeset`, `export`, `readonly`, `local`, `for x in`, `((x=1))`, `let`, `printf -v`, and
`read`/`readarray`/`mapfile` with per-command option tables so `read -d '' name` and
`mapfile -d '' -t name` do not lose their variable to an option argument. It runs in both
directions: a forgotten assignment reddens, and so does a dead reset entry.

Embedded programs are excised by structure rather than by hoping their lines look
different from bash. A `$(awk '…')`, `$(sed '…')`, or `$(jq '…')` region is skipped from
its opening quote to its close, while the opener line's own bash prefix is kept — that is
where the capture is assigned, so `workflow_call_block` is still collected while the awk
program's `seen_block=1` is not. The earlier claim that awk "cannot forge a name" because
its lines begin with `$0` or a bare word was an incidental property of today's program,
not a guarantee; it has been withdrawn.

The carry-over exemptions are `repositories_scanned`, `consumers`, `failures`, and `IFS`,
established by reading the script rather than inherited from the review. The first three
are fleet totals reported after the loop closes; `IFS` is exempt only in the
command-prefix form, which bash scopes to the single command it precedes. The check now
proves that rather than asserting it in prose: every `IFS=` site must be followed by a
command on the same segment, so a standalone `IFS=,` would be ordinary loop state and
reddens instead of inheriting the exemption. `visibility` and
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
| an assignment reachable only through a `case` arm, `[ … ] &&`, `[ … ] ||`, `declare`, `typeset`, `export`, `readonly`, `local`, `for … in`, `((…))`, `let`, `read -a`, `read -d ''`, `readarray -t`, `mapfile -d '' -t`, `printf -v`, or `if ! name="$(…)"` | `assigned per repository but never reset:` naming that variable, one injection per form |
| a name assigned only inside an embedded `awk` program | nothing — the region is excised, so it is not mistaken for loop state |

`Verjson/.github#1471` would widen the shipped extractor so the 40-hex guard is reachable
from a real fixture, which would retire the mutated-copy fixture and with it the
confinement assertion above. That is a deliberate sequencing choice recorded here, not an
oversight: the assertion is cheap and honest today, and removing it is #1471's job.
