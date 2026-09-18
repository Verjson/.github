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

The assertion now walks the loop body for the assignment forms enumerated below rather
than the handful the script happens to use today, and requires the reset to name all of
them. That list was built by exercising the collector, one injection case per form; it is
not a claim that bash offers no other form, and the withdrawal at the end of this fragment
applies to it as much as to anything else here. The
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

`${name:=…}` is read per word, not over the raw line. It assigns wherever bash *expands*
it — unquoted and inside double quotes alike — so the previous version matched it against
the whole raw line, before quoting or comments were considered. That forged names bash
expands nowhere: `echo '${ghost:=1}'` and `metadata=2  # see ${ghost:=1}` were both
collected, and `g` is unset after either under real bash. Forging is the **silent**
direction, because a forged name keeps a dead reset entry green — both were verified green
before this change, exit 0 with a reset entry nothing assigns. The expansion is now matched
per word over the words `segments()` yields, which has already dropped a trailing comment
and tracked the quoting, and a quote-aware scan inside each word skips single-quoted spans.

That scan honored a backslash escape only inside double quotes, but bash honors one outside
quotes too: `echo \${e1:=1}` expands nothing and leaves `e1` unset (`declare: e1: not
found`), while the collector collected `e1`. That is the same forging direction, reached by
a third route, and forging is the silent one. The scan now skips an escaped character
wherever a single-quoted span is not in effect, which is exactly where bash honors it.
Both directions of all three surfaces are injection cases.

A `case` arm label that spells an assignment forged the same way, found while checking
whether the two surfaces above were the only ones of their class. `case "$x" in a=1) : ;;`
assigns nothing in bash, but the arm-label lead-in pattern excluded `=`, so `a=1)` fell
through to the command-prefix rule and was collected as an assignment to `a`. The lead-in
now admits `=` inside an arm label.

Admitting `=` was necessary but not sufficient, and the justification previously written
here for it — *"an assignment word can never end in `)` without an unbalanced `(` the
pattern already excludes"* — was false twice over, and is withdrawn. `x=b\)` ends in `)`
and is balanced; and the pattern never required end-of-word at all, being a prefix match.
Widening the class to `[^()\s|]+` therefore discarded, as an arm label, any word carrying a
`)` before its first `(`. Four real assignments went silently missing: `x="b)"`, `x='b)'`,
`x=${r%)}` and `x=b\)`, each confirmed assigned under `declare -p`, each collected by the
narrower pre-widening class, and a miss is #1448's own bug class.

What the lead-in relies on now is stated by the pattern rather than by prose about bash: an
arm label is the **whole** word, and its terminating `)` is **unescaped** —
`\(?[^()\s|]*[^()\s|\\]\)$`. Anchoring to end-of-word is what recovers `x="b)"`, `x='b)'`
and `x=${r%)}`; requiring the `)` to be unescaped is what recovers `x=b\)` too, and it is
also what still separates `x=b\)` from the arm label `a=1)`. All four recovered forms are
injection cases, as are both directions of the `a=1)` forge and the arm-label shapes the
corpus already pins: `a)`, `(a)`, and a `case` nested inside an arm. The remaining shapes
the loop actually uses are exercised by the primary run against the real audited script
rather than by a fixture — `ahead|identical)` and `"")` at
`scripts/privileged-merge-conformance.sh:337-338` and `*)` at `:339`; the arm at `:483`,
`all) has_secret=true ;;`, is the one that binds an arm label to an assignment on the same
segment, and `has_secret` is a name the reset must list, so that run is not vacuous. The
`b)` half of an alternation label matters because `segments()` splits on the unquoted `|`,
so that half starts its own segment and must strip with no `case … in` in front of it;
that is why the lead-in strips arm labels generically rather than only after `in`.

Anchoring costs one shape, recorded rather than glossed: an arm label whose own `)` is
backslash-escaped — `case … in a\)) x=1 ;;` — is no longer stripped, so an assignment
sharing that segment is missed. The plain end-of-word anchor misses it identically, so the
unescaped requirement is free; it is a **miss**, the same direction as the four it recovers
and never a forge; and it is pinned as an injection case so it cannot drift.

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

Which mechanism absorbs which text is now measured rather than assumed. The six
multi-line `absorbed` rows were credited to the excision; they are not. Hard-wiring
`opens_embedded` to `return False`, disabling every excision, left the whole corpus green
before this change — 0 failures — because the newline collapse absorbs multi-line program
bodies on its own. Mutating the collapse instead reddens 2 of those 6 rows; the other 4 are
absorbed by either mechanism independently, which is defense in depth rather than a pin on
either. The excision *is* load-bearing — an assigning expansion inside a **single-line**
double-quoted program is text the per-word walk would otherwise read — so that is now an
injection case, and it is the only row that reddens when the excision is disabled.

A double-quoted embedded region no longer closes at an escaped quote. `awk "a\"b"` was cut
at the `\"`, leaving text that `bash -n` rejected. That never forged and never swallowed —
it misreported a valid program as unparseable bash, which is loud. A previous revision of
this fragment credited "810 adversarial escaped-quote fixtures produced zero silent passes"
here; that figure is not reproducible from anything on this branch and is withdrawn. What
is measurable is the injection case that pins it, which is one of the 10 rows the previous
revision of the collector fails. A comment on the loop body's final line is likewise
closed by the end of the body rather than by a newline, which the scanner previously
reported as an unterminated region.

The `bash -n` assertion now runs after the membership assertions rather than before them,
so a parse failure cannot mask the drift finding this contract exists for. A parse failure
does mean the excision cut wrong, so a membership finding raised alongside one carries the
parse error in its own message and is marked as possibly an artifact; neither hides the
other.

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
are **80** of them, each mutation must find its anchor, and the count itself is asserted,
so the corpus cannot rot into vacuous passes when the loop moves underneath it or shrink
silently when a case is dropped.

Its non-vacuity is measured against three collectors rather than asserted:

| Collector the corpus is run against | Corpus result |
| --- | --- |
| the collector as it stood before this whole change (`9a5d237`) | **24 of 80 fail** |
| the collector as it stood one revision ago (`eb1a2af`) | **10 of 80 fail** — the three forging surfaces above in both directions, the backslash-escape surface in both, the escaped-quote misreport, and the escaped arm-label boundary |
| this collector with `opens_embedded` hard-wired to `return False` | **1 of 80 fails** — before this change it was 0, which is what showed the excision was unpinned |

Staying green against a mutant collector is not by itself distinguishing — 55 of the 80
rows are green against all three, because each mutant regressed only part of the collector.
What distinguishes a row is surviving a *mechanism* being disabled. Disabling the newline
collapse reddens exactly 2 of the 6 multi-line `absorbed` rows, and disabling the excision
reddens exactly 1 row, which is a different one. So **four** multi-line `absorbed` rows —
the `awk`, `jq`, `gh --jq`, and double-quoted `sed` bodies — are green under both mechanism
mutants and are absorbed by either mechanism independently. Those are the same four the
"Which mechanism absorbs which text" paragraph counts as "the other 4". The heredoc
`boundary` row pins a recorded miss rather than a mechanism at all, and stays green
against every collector measured here; with it,
five rows are pins on the record rather than on a mechanism.

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
| an assignment whose value ends in `)` — `x="b)"`, `x='b)'`, `x=${r%)}`, `x=b\)` | `assigned per repository but never reset:` naming that variable — four words the widened arm-label class discarded as labels |
| `\|\| name=1` written past an embedded region's closing quote | `assigned per repository but never reset: ['past_the_region']` |
| real bash after a non-opener `jq` word in a string, after an apostrophe in a `jq` diagnostic, or after a double-quoted `sed` program | `assigned per repository but never reset:` naming it — the three silent swallows found in review |
| an embedded program's closing quote is deleted | `the excised loop body no longer parses as bash` |
| a multi-line `awk`, `jq`, `sed`, `gh --jq`, or `--jq=` program body, or a multi-line quoted string that is no program at all | nothing — the region is excised, so program text cannot forge a name |
| a dead reset entry whose name only `awk` or `gh --jq` program text spells | `reset but never assigned in the loop:` naming it — the excision closes the silent direction too |
| `${name:=1}` inside single quotes, in a trailing comment, behind a backslash escape, or a `case` arm label spelling `a=1)` | nothing — bash expands none of them, so none may be collected |
| a reset entry whose name only single-quoted text, a trailing comment, backslash-escaped text, or a `case` arm label spells | `reset but never assigned in the loop:` naming it — the silent direction of each of those four |
| a single-line double-quoted `sed` program body containing `${name:=1}` | nothing — the one row the excision alone absorbs |
| a double-quoted `awk` program containing an escaped quote | nothing — an escaped quote does not close the region |
| a `<<'EOT'` heredoc body naming a variable the reset does not list | `assigned per repository but never reset: ['forged_by_heredoc']` — the loud direction of the documented miss |
| a `<<'EOT'` heredoc body naming a variable the reset **does** list | nothing — the **silent** direction of the same documented miss, pinned as a known miss |
| `case … in a\)) x=1 ;;` — an arm label whose own `)` is backslash-escaped | nothing — the documented cost of anchoring the arm label to the end of the word, pinned as a known miss |

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
- **A `case` arm label whose terminating `)` is backslash-escaped is not stripped**, so an
  assignment written in the same segment — `case … in a\)) x=1 ;;` — is missed. This is the
  price of anchoring the arm label to the end of the word, which is what lets an assignment
  word contain a `)` at all; the plain end-of-word anchor misses it identically. It is a
  miss, never a forge, and an injection case pins it.
- **ANSI-C quoting `$'…'` is not modelled.** `echo $'a\'${x:=1}'` assigns nothing under
  bash, but the collector reads the `\'` as a literal inside a single-quoted span and ends
  the body inside an unterminated region, reporting `the loop body ends inside an
  unterminated quote, command substitution, or embedded program region`. That is **loud**
  — a false alarm, not a forgery — so it is recorded rather than closed. The audited script
  uses no `$'…'`.
- **A `<<'EOT'` heredoc body is parsed as bash**, so `foo=bar` inside one is collected as a
  name — and it is silent in one direction, not loud in both. A previous version of this
  list called it "a loud miss" without qualification; that was half true. If the reset does
  **not** list the name, the forgery reddens as
  `assigned per repository but never reset: ['forged_by_heredoc']` — loud, a nuisance for
  whoever adds a heredoc. If the reset **does** list it, the same forgery keeps a dead reset
  entry green, exit 0, and nothing says so. Both directions are now injection cases, the
  silent one pinned as a known miss so closing it has to be recorded here.

**No exhaustiveness claim is made here, and the two previous attempts at one are
withdrawn.** The first said "every remaining gap fails toward a miss, not toward a forged
pass"; the `gh --jq` program body and multi-line quoted strings falsified it. The second
narrowed it to "the only text the collector still hands to the bash tokenizer without
reading it as data is a heredoc body, which forges loudly"; that was falsified twice over —
the raw-line `${name:=…}` match forged from single-quoted text and from comments, neither
of which is a heredoc and neither of which is loud, and a `case` arm label spelling `a=1)`
forged as well. The heredoc itself is not loud in both directions.

A third narrowing would be worth no more than the first two, because each was written by
reading the code rather than by exercising it, and each was refuted by exercising it. What
replaces the claim is the measurement: the forging surfaces **known** to exist are the
heredoc body (both directions), and — before this change — single-quoted text, trailing
comments, backslash-escaped text, and `case` arm labels (both directions each). All are
injection cases, closed where they could be closed and pinned where they could not. The
corpus and the three mutant-collector figures above are the evidence about what this
check catches; the boundary list is what has been found, not a proof that nothing else is
there.

`Verjson/.github#1471` would widen the shipped extractor so the 40-hex guard is reachable
from a real fixture, which would retire the mutated-copy fixture and with it the
confinement assertion above. That is a deliberate sequencing choice recorded here, not an
oversight: the assertion is cheap and honest today, and removing it is #1471's job.
