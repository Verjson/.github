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
`export`, `readonly`, `local`, a nameref *declaration*, `for x in`, the `in`-less `for x`
that iterates the positional parameters, `select x in`, `coproc`, `getopts`, `let`,
`printf -v` including `printf -v 'a[0]'`, `${x:=y}`, `case` arms written single-line,
parenthesized as `(x)`, and nested inside one another, `read`/`readarray`/`mapfile` with
per-command option tables so `read -d '' name` and `mapfile -d '' -t name` do not lose
their variable to an option argument, a bare `read`, which assigns `REPLY`, and arithmetic
in full: `((x=1))`, every compound operator including `**=`, `((x++))`, comma-separated
targets, and a C-style `for ((x=0; x<2; x++))` header. `((n++))` is a plausible replacement
for the loop's own `n=$((n + 1))` counters, so that is not hypothetical. It runs in both
directions: a forgotten assignment reddens, and so does a dead reset entry.

Embedded programs are excised by structure rather than by hoping their lines look
different from bash, and **openers are decided in word position by the same character
scanner that tracks quoting**, not by a regex over the raw line. The raw-line regex was a
second-order version of the same mistake this contract exists to catch: it could not tell
`jq -e '` from the word `jq` inside `echo "needs jq here"`, so any `awk`/`sed`/`jq` word
followed by an apostrophe anywhere later on the line opened an excision.
`echo "needs jq here" && swallowme='1'` passed green with `swallowme` never collected, and
`echo "::error::the jq binary isn't present"` left the region open until the next
apostrophe anywhere below it, silently discarding nineteen lines of loop body along with
the assignment written on the following line.

The region now runs from its opening quote to the matching quote **of the same character**,
and it is spliced from the opening quote rather than from the command word. The audited
script's dominant embedded idiom is the double-quoted `sed -nE "s/…'(…)'…/p"` at
`scripts/privileged-merge-conformance.sh:303`, `:383`, `:431`, `:439`, and `:442`; cutting
that at the single quote *inside* the program dropped the opening `"` and left the
remainder unbalanced — the same silent swallow, one quoting style over.
`sed -nE "s/a'b/c/p" /dev/null && swallowme=1` was green before this change.

`gh --jq '…'` is an embedded program too, even though `gh` is the command word. `--jq`
leads with `-`, so no command-word rule can see it, and a multi-line `--jq` program was
handed to the bash tokenizer verbatim: a name spelled in its body was collected as loop
state. That direction **forges**, and forging is what keeps a dead reset entry green. The
loop calls `--jq` at `scripts/privileged-merge-conformance.sh:214`, `:241`, `:278`, `:331`,
`:350`, `:355`, and `:360`, so this was live rather than hypothetical. The option now arms
the next quoted word exactly as an embedded command word does.

A newline inside a quoted string is data, not a command separator, so the scanner collapses
it. Without that, the inner lines of any multi-line quoted string that is not recognized as
a program — an `echo '…'` spanning lines, or a `--jq='…'` written as one word — were handed
to the per-line tokenizer as if they were bash, which is the same forging surface reached
by a different route. A newline inside `$( … )` is a real separator and is preserved.

The region is spliced out **in place** rather than dropped as whole lines. The regions sit
inside `"$(…)"`, so emitting the opener's prefix and the closer's remainder as two separate
lines leaves each half with an unbalanced quote, and the tokenizer then swallows anything
written past the program's closing quote — including `|| name=1`, which is the loop's
dominant idiom. Splicing keeps `workflow_call_block="$(awk EMBEDDED_PROGRAM <<<…)" || …`
balanced, so the capture is still collected, the program body is not, and real bash on the
terminating line is.

The closure guard is no longer a "the region eventually closed" check, which was very
nearly vacuous: deleting the awk program's closing quote at
`scripts/privileged-merge-conformance.sh:371` used to exit 0, because a later apostrophe
closed the region on its behalf. The excised body is now handed to `bash -n`, so an
excision that cut at the wrong quote, or one that swallowed real commands, is caught by the
text no longer parsing. That is the invariant the guard is credited for, and it is
exercised by an injection case rather than asserted.

Continuations are joined before anything else reads the text. The reset statement was
already continuation-joined; the assignment walk was not, so any name written past a `\`
wrap was dropped silently. The loop already wraps at `:206-217` and `:241`, and the reset
list is long enough that a wrapped `read` is a plausible next edit. Joining an *interior*
continuation is what bash itself does, so the accompanying `assert not pending` guards only
the body's final line; a genuinely malformed continuation surfaces through `bash -n`.

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

## The capability table is executed, not described

Every row below is an injection case: a mutated copy of the audited script, fed to the
collector, required to redden with the stated message rather than merely to redden. There
are **64** of them, and each mutation must find its anchor, so the corpus cannot rot into
vacuous passes when the loop moves underneath it. Run against the collector as it stood
before this change, 14 of the 64 fail — which is the measurement that made the prose in the
previous version of this fragment worth distrusting.

| Mutation | Assertion that fires |
| --- | --- |
| reset list loses `metadata default_branch visibility_type has_secret` | `assigned per repository but never reset: ['default_branch', 'has_secret', 'metadata', 'visibility_type']` |
| a new loop variable is added and forgotten | `assigned per repository but never reset: ['newly_added_state']` |
| reset list gains a name the loop never assigns | `reset but never assigned in the loop: ['never_assigned_anywhere']` |
| reset clears a fleet accumulator | `the reset clears a value the fleet audit must carry` |
| reset returned to the bottom of the loop | `early exits precede the reset:` |
| a second top-level `unset` | `expected exactly one per-repository reset, found 2` |
| fleet-wide state moved into the loop | `fleet-wide state moved into the loop body` |
| `IFS=,` written as loop state rather than a command prefix | `IFS is assigned as loop state, not a command prefix` |
| each assignment form in the paragraph above, one injection per form | `assigned per repository but never reset:` naming that variable |
| `\|\| name=1` written past an embedded region's closing quote | `assigned per repository but never reset: ['past_the_region']` |
| real bash after a non-opener `jq` word in a string, after an apostrophe in a `jq` diagnostic, or after a double-quoted `sed` program | `assigned per repository but never reset:` naming it — the three silent swallows found in review |
| an embedded program's closing quote is deleted | `the excised loop body no longer parses as bash` |
| a multi-line `awk`, `jq`, `sed`, `gh --jq`, or `--jq=` program body, or a multi-line quoted string that is no program at all | nothing — the region is excised, so program text cannot forge a name |
| a dead reset entry whose name only `awk` or `gh --jq` program text spells | `reset but never assigned in the loop:` naming it — the excision closes the silent direction too |
| a `<<'EOT'` heredoc body | `assigned per repository but never reset: ['forged_by_heredoc']` — a documented loud miss, pinned so it stays loud |

## Where the collector stops

It is a pragmatic bash tokenizer, not a bash parser, and the boundary is recorded
deliberately, because the boundary list is what made the review that found these holes
possible.

- **Bash inside a deferred-execution string is not followed.** `eval`, `source`, and
  `trap 'x=1' EXIT` are misses. The audited script uses none of them.
- **A write *through* a nameref is not followed.** `declare -n x=y` is collected as an
  assignment to `x`, which is correct, but a later `x=1` writes `y` and the collector
  cannot know that. A previous version of this list named `declare -n` and `local -n`
  themselves as boundaries; that was inaccurate — they were always collected, and an
  injection case now pins it.
- **An assignment inside a function defined in the loop body** is not modelled.
- **An assignment inside an excised program's own `$( … )`** goes with the excision.
- **A `<<'EOT'` heredoc body is parsed as bash**, so `foo=bar` inside one is collected as a
  name. That fails *loudly*, and the corpus pins it as
  `assigned per repository but never reset: ['forged_by_heredoc']`, so it is a nuisance for
  whoever adds a heredoc rather than a correctness hole.

A previous version of this fragment closed by claiming that "every remaining gap fails
toward a miss, not toward a forged pass". **That claim was false when it was written.** The
`gh --jq` program body forged a name — the direction that keeps a dead reset entry green —
and so did the inner lines of any multi-line quoted string the excision did not recognize.
The claim is withdrawn rather than narrowed. What replaces it is checkable: the only text
the collector still hands to the bash tokenizer without reading it as data is a heredoc
body, which forges **loudly** and is pinned by the corpus; every other boundary above fails
toward a miss. If a future edit widens that set, the corpus is where it has to be recorded.

`Verjson/.github#1471` would widen the shipped extractor so the 40-hex guard is reachable
from a real fixture, which would retire the mutated-copy fixture and with it the
confinement assertion above. That is a deliberate sequencing choice recorded here, not an
oversight: the assertion is cheap and honest today, and removing it is #1471's job.
