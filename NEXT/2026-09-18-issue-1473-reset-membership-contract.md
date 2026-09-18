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
word. Segments split on an unquoted `|` as well as `&&`, `||`, and `;`, so the word after
a pipe is still a command; brace groups and `command`/`builtin`/`env` are lead-ins; and
candidate names are unquoted, because `read -r "name"` names a variable exactly as
`read -r name` does.

That covers `=`, `+=`, indexed and associative element assignment, `declare`, `typeset`,
`export`, `readonly`, `local`, `for x in`, `select x in`, `coproc`, `getopts`, `let`,
`printf -v`, `${x:=y}`, single-line and multi-line `case` arms, `read`/`readarray`/`mapfile`
with per-command option tables so `read -d '' name` and `mapfile -d '' -t name` do not lose
their variable to an option argument, and arithmetic in full: `((x=1))`, compound operators,
`((x++))`, comma-separated targets, and a C-style `for ((x=0; x<2; x++))` header. `((n++))`
is a plausible replacement for the loop's own `n=$((n + 1))` counters, so that is not
hypothetical. It runs in both directions: a forgotten assignment reddens, and so does a
dead reset entry.

Embedded programs are excised by structure rather than by hoping their lines look
different from bash, and the command is matched in *word* position — bare, after `!`,
after a pipe, or inside `$(`/`<(`, with any options between it and its opening quote. An
earlier attempt keyed on a literal `$(` and so matched exactly one of the three regions in
the loop; both multi-line `jq -e '` programs at `scripts/privileged-merge-conformance.sh:392`
and `:453` were handed to the bash tokenizer verbatim. That was a live false negative in
both directions: jq text could forge a name, and — worse, because green tells you nothing —
jq text spelling a name the loop no longer assigns kept a dead reset entry green.

The region is spliced out **in place** rather than dropped as whole lines. The regions sit
inside `"$(…)"`, so emitting the opener's prefix and the closer's remainder as two separate
lines leaves each half with an unbalanced quote, and the tokenizer then swallows anything
written past the program's closing quote — including `|| name=1`, which is the loop's
dominant idiom. Splicing keeps `workflow_call_block="$(awk EMBEDDED_PROGRAM <<<…)" || …`
balanced, so the capture is still collected, the program body is not, and real bash on the
terminating line is.

Continuations are joined before anything else reads the text. The reset statement was
already continuation-joined; the assignment walk was not, so any name written past a `\`
wrap was dropped silently. The loop already wraps at `:206-217` and `:241`, and the reset
list is long enough that a wrapped `read` is a plausible next edit.

The earlier claim that awk "cannot forge a name" because its lines begin with `$0` or a
bare word was an incidental property of today's program, not a guarantee; it is withdrawn,
and for the two jq regions it had never been true in the first place.

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
| a name assigned only inside an embedded `awk` or `jq` program | nothing — all three regions are excised, so program text is not mistaken for loop state |
| a dead reset entry whose name the `awk` or `jq` program text happens to spell | `reset but never assigned in the loop:` naming it — the excision closes the silent direction too |
| `\|\| name=1` written past an embedded region's closing quote | `assigned per repository but never reset:` naming it |
| a name written past a `\` continuation, in a `read` or a `mapfile` | `assigned per repository but never reset:` naming it |
| an assignment after an unquoted `\|`, inside `{ … }`, or after `command` | `assigned per repository but never reset:` naming it |
| `((x++))`, `((a=1, x=2))`, or a C-style `for ((x=0; …))` header | `assigned per repository but never reset:` naming it |
| a quoted candidate name — `read -r "x"`, `printf -v "x"`, `declare "x=1"` | `assigned per repository but never reset:` naming it |
| `coproc x`, `getopts … x`, `select x in`, `: "${x:=y}"`, single-line `case` | `assigned per repository but never reset:` naming it |

Where the collector stops is recorded deliberately, because that boundary list is what
made the review that found these holes possible. It is a pragmatic bash tokenizer, not a
bash parser: it does not model `eval`, `source`, `declare -n` namerefs, or assignment
inside a function defined in the loop body — none of which the audited script uses. A
`<<'EOT'` heredoc body is parsed as bash, so `foo=bar` inside one is collected as a name;
that fails *loudly* — verified as `assigned per repository but never reset:
['forged_by_heredoc']` — so it is a nuisance for whoever adds a heredoc rather than a
correctness hole. Every remaining gap fails toward a miss, not toward a forged pass; the
two silent directions found in review are both closed and asserted.

`Verjson/.github#1471` would widen the shipped extractor so the 40-hex guard is reachable
from a real fixture, which would retire the mutated-copy fixture and with it the
confinement assertion above. That is a deliberate sequencing choice recorded here, not an
oversight: the assertion is cheap and honest today, and removing it is #1471's job.
