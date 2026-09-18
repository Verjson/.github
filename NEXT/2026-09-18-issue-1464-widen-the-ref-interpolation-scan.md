---
date: 2026-09-18
issue: 1464
impact: patch
title: Widen the ref-interpolation scan past its two URL shapes
---

The `default-branch-uri-encoding` gate recognized ref interpolations in only two URL
shapes, so a positional encoding error in any other ref-bearing path passed green. The
scan now anchors on every ref-bearing GitHub REST path segment — `git/ref[s]/heads/`,
`commits/`, `git/commits/`, `git/trees/`, `git/tags/`, `branches/` including
`rules/branches/`, and both operands of a `compare/A...B` range — and treats `${VAR}` as
the same shell interpolation as `$VAR`. Recognized sites went from 35 to 77.

Three real defects the widened scan surfaced are fixed here. `ai-review-merge.yml` built
`compare/$base_ref...$head_sha` with the base branch name unencoded, directly under a
comment claiming a slash in a branch name could not confuse the `...`-path.
`dependency-supersession-reconcile.yml` read `commits/$default_branch` unencoded and did
not constrain the resulting head. `container_deployment_review_producer.py` accepted
`--deployment-commit`, and read a pull request's `head.sha`, into a `commits/` path
segment without constraining either to a 40-hex object name.

Two more sites are fixed rather than excused: the `eligibility` job in `node-ci.yml`,
`node-ci-protected.yml`, and the co-located `ci-eligibility` composite action now
constrain `HEAD_SHA` to a 40-hex object name before it reaches a `commits/<sha>/status`
path. `node-ci-protected.yml` took a caller-supplied `inputs.head-sha` there, and the
only assert on that value lived in a job declaring `needs: eligibility`, so it ran
strictly later and could not vouch for the use.

Fourteen further sites that the scan cannot prove at the point of use are named in an
explicit `REF_SITE_ALLOWLIST`, eleven entries with a reason each, in three classes: a
40-hex object name whose constraint lives in another step, function, or caller; an object
name supplied by GitHub that no repository-local guard constrains; and a ref name carrying
a stated non-encoding guard. An entry that cites a guard now pins that guard's literal
text, so deleting the cited check reddens this gate instead of leaving the entry vouching
for a value nothing constrains. A stale entry fails too, so the list cannot rot into a
silent hole. `scripts/assert-mergeable-head.sh` is allowlisted with an unresolved conflict
recorded at the entry: it encodes a `rules/branches/` segment in the query form, and
`scripts/ci-gate/verify-arm-receipt.sh` interpolates that segment with no encoding at all,
while four other sites use the path form for the same endpoint. `branches/` and `commits/`
were measured against the live API to accept both forms; `rules/branches/` could not be
settled because no Verjson ruleset targets a slash-bearing ref.

The scan also rejects a file that re-binds `quote` at module scope, which would otherwise
be judged by the stdlib encoder it does not call. A new section 0 measures each anchor
shape against synthetic fixtures, and the file header now states the remaining ceiling:
Python string concatenation and `%`-formatting are a deliberate, stated non-goal, as are
Python embedded in workflow YAML, shell positional parameters, and interpolations split
across source lines.

The recognized-site count is pinned, not merely printed: moving an interpolation out of a
recognized shape — concatenation instead of an f-string brace, a `compare/` prefix hoisted
into a variable — lowered coverage while every remaining site still passed.

ADR 0194 records the merge-authorization consequence: the unencoded base ref failed OPEN,
because a misresolved compare request was swallowed to `behind=0`, skipping the branch
update and merging on a review performed against a stale base.

The boundary validation added to `scripts/container_deployment_review_producer.py` moves
the container-deployment contract digest, so adopters must regenerate at a new contract
SHA.

A cited guard is checked for still FAILING, not merely for being present or uncommented.
`grep -F` alone found the text anywhere in the file, so commenting the guard out or
appending `|| true` left this gate green — the same rot one level up. A first pass added a
denylist of four swallowing literals; an independent re-review then showed that denylist
was under-specified, and that against the cited guard in `gate-rearm.yml` six further forms
(`||:`, `|| { :; }`, `|| echo skipped`, `| cat`, a trailing `&`, `|| exit 0`) all kept the
gate green, while the inline 40-hex proof — the anchor for the `HEAD_SHA` constraint this
change adds to node-ci — had no liveness treatment at all and accepted every one of them
plus an outright comment-out.

The anchor is now an allow-list, not a denylist, and command-level, not line-level. It
joins continuations first — a trailing `\`, a trailing `&&`/`||`/`|`, and a multi-line
`|| { … }` branch are one command — which is what closes the shape this change itself
introduced, where node-ci writes the guard on one line and its `|| { …; exit 1; }` on the
next. It then requires the tail after the pinned text to be one of the shapes that leave
the guard: `|| exit N`, `|| return N`, `|| continue`, `|| break`,
`|| fail|fault|die|abort …`, a `|| { … }` whose body contains one of those, or nothing at
all, which under `set -euo pipefail` means the guard's own status is the command's.
Anything else reads as disarmed, so a swallow nobody has written yet reddens rather than
passing. All eight forms, the continuation-line `|| true`, and the accepted shapes are
permanent regression cases against synthetic fixtures.

A second re-review then falsified that allow-list too, and the correction is the more
important one. Its brace alternative matched the fatal action as a *substring* of the
`{ … }` body, with no notion of command position — a denylist wearing an allow-list's
clothes. Mutating the real guard at `node-ci.yml:437`, the `|| true` control reddened while
seven forms did not: `|| { echo "would exit 1 here"; }` (matched inside a string),
`|| { ( exit 1 ); }` (exits the subshell only), `|| { false && exit 1; }` (unreachable),
a `cat <<EOF` / `exit 1` here-document (printed, not run), `|| exit 256` and `|| return 256`
(wrap to a 0 wait status), and `|| continue` / `|| break` with no enclosing loop (bash warns
and carries on).

The allow-list now reasons about command position. Quoted spans, `#` comments, `${…}`,
`$(…)` and `(…)` subshells are blanked first; a `|| { … }` branch is closed by brace depth,
so a closer carrying a tail (`} >&2`) no longer buffers the rest of the file into one
logical line and a nested `}` no longer closes the body early; `exit`/`return` statuses are
bounded to 1–255, zero-padding allowed; and a brace body counts only when it is flat and
one of its top-level statements is *exactly* a fatal action. Each of the seven forms is now a permanent
regression case and each was verified by mutating the real `node-ci.yml` guard and observing
a non-zero exit. Two fail-closed false positives are fixed in the same pass: a `}` closer
carrying a tail, and a trailing `\` inside a comment, which joined the comment to the next
line and read a live guard as commented out.

The stated ceiling is now split by direction, because the previous version listed only three
fail-open classes and named none of the ones above. Fail-closed: `exit 300` is rejected
though it is fatal; a nested *brace* group or a *here-document* in a brace body is not
flattened,
while a plain redirection (`>&2`, `>/dev/null`, `2>&1`) is flattened and still reads fatal —
it has to, because writing the diagnostic to stderr inside the failure branch is how this
repository spells a fatal `|| { … }`; `scripts/gen-adr-index.sh:106` and
`.github/workflows/node-release.yml:318` are two, read and verified — and the stricter rule
this note used to claim would report every guard so written disarmed. No count of them is
stated. ADR 0194 records the universe and the predicate anyone re-deriving one must
reproduce, and why no figure accompanies them: the universe is
the scan's own 144-file set and the predicate is this gate's own `logical_lines slice` plus
`brace_body_is_fatal` with `>&2` in the source text. No denominator is published, for the
reason given at the end of this note. `continue`/`break` are never accepted, in or out of a
loop; a
positive `if <guard>; then <use>` is not accepted, nor a negated branch whose only `else`
belongs to a nested `if`, nor one where the guard is merely an operand of a `&&`/`||` in the
condition; an action reached only through a `&&`/`||` chain is not treated as
unconditionally reached, because this anchor does not evaluate conditions; the structural
pass is lexical and models neither here-documents, `case` patterns, nor quoting nested
inside `$(…)`. Fail-open, and therefore the real ceiling: a guard moved into a branch that
never runs, the negated-branch proof's two residuals above, a guard made vacuous by editing
the value it tests, any terminating word
redefined as a no-op — `exit` and `return` can be shadowed by a function, so this covers the
whole allow-list rather than just `fault` — and the pinned literal matched inside a string
rather than as a command, since the literal search runs over raw text.

A guard is also recognized when it is spent as the NEGATED condition of an `if`/`elif`
whose protected use sits in the sibling `else` arm — `elif ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]];
then`. Nothing follows such a guard on its own command but `; then`, so the fatal-tail
allow-list cannot judge it and reported it as no constraint at all; the proof is structural
instead, because the arm the guard opens is the failing one and cannot fall through to the
`else`. `scripts/privileged-merge-conformance.sh:327` is exactly that shape — its protected
`gh api …/compare/$caller_contract_sha…main` is at `:331`, inside the `else` — and four of
its `gh api` uses were reported unconstrained by a scan that was green at this branch's own
head and red once merged.

The first version of that proof asked only whether an `else` EXISTED at the guard's own
depth, which is a fail-open, and round 4 found seven shapes it accepted that still ran the
use with an unchecked value: a non-terminating `then` arm with the use after `fi`, two empty
arms, a `then` arm of `exit 0` — the swallow the tail allow-list rejects by name — the use in
the `else` *and* again after `fi`, the construct wrapped in a loop, a `then` arm calling a
helper nothing proves terminates, and the `elif` form of the first. It also split two cases
that are the same program, accepting a vacuous `else` where it rejected the pinned no-`else`
fixture. What is required now is that the guard's failing arm cannot reach the use, by one of
two facts: either the use lies inside the `else`/`elif` **extent**, or the `then` arm
**terminates**, judged with the same `exit N`/`return N`/named-helper notions the tail
allow-list uses rather than a third idea of termination. The pinned use is the last record of
the input, which in `slice` mode is exact because the block slice is cut at the use's own
line. `if ! guard; then echo …; exit 1; fi` — read as disarmed before — is accepted as a
result.

Both residuals are named in the ceiling rather than left implicit. The proof is positional,
not dataflow: it shows the use's *line* is in the protected arm, not that the value reaching
the use is the value the guard tested. And in `whole` mode — an allowlist entry's pinned
guard, read from a whole file — there is no use to locate, so the end of the file stands in
for it; no allowlist entry is written that way, and `slice` mode, which the
privileged-merge-authorization path uses, is exact.

Every one of those shapes is pinned as a regression case, on both the whole-file and the
block-slice path, alongside the five that were already rejected correctly. Acceptance was
verified by mutating the real guard at `:327` to `elif false; then` and by replacing its
`else` with `fi`, each observed to exit non-zero; the new rejections were verified by
restoring the else-exists rule and by making the `then`-arm termination test accept anything,
each observed to redden the fixtures that pin them.

The lexical `do`/`done` loop-depth count that let `continue`/`break` leave a guard is
deleted, along with `continue`/`break` support itself — roughly 60 lines. It carried a
fail-open of its own: `slice` mode, the mode the privileged-merge-authorization path uses,
waived the balance requirement `whole` mode enforced, so a statement that is exactly `do` —
in prose, or inside a here-document body the structural pass does not model — licensed
`continue`/`break` for everything after it in the slice. It was also no longer load-bearing:
main's #1466 rewrote `privileged-merge-conformance.sh:314`, its one real consumer, into an
`elif`, and forcing the count to report depth 0 everywhere on the merged tree failed nothing
but the fixtures that tested the count itself. A named fail-closed gap replaces it: a guard
that protects a URL by skipping its loop iteration now reads as disarmed, and no current
site is in that shape.

A Python guard gets the comment check and nothing more. Every cited Python guard is a
sub-expression of an `if … is None:` or a `require(…)` call, with no single tail shape
meaning "this raises", so five of the eleven allowlist entries are pinned only as "the cited
check is still written" — not that it still rejects anything, and a green run must not be
read as though it did. The one Python-shaped denylist literal that used to be there,
`or True`, is dropped rather than kept: a one-entry denylist reads like protection while
catching nothing adjacent to it (`or 1`, `or (lambda: True)()`, a `require` redefined
above), which is the same failure the shell side is being moved away from.

Read the shell pin as "the cited text is still written outside a comment, and the
continuation immediately following it is one of the listed shapes" — not as "the guard still
fails". Three earlier versions of that sentence claimed more than the code could support.

The scan's file set is also named in the ceiling now: it covers `.github/workflows/*.yml`,
`scripts/*.sh` and `scripts/*.py`, and NOT `.github/actions/*/action.yml`. The
adopter-facing `commits/${HEAD_SHA}/status` read in the `ci-eligibility` composite action
is therefore never judged by this gate directly; it is covered by the byte-parity assertion
between that composite script and node-ci's inline copy, and only while that assertion
holds.

The new `HEAD_SHA` constraint is covered by its own negative cases rather than only by the
positive ones continuing to pass. Eight non-40-hex values — a short SHA, a branch name, a
traversal suffix, an uppercase SHA, the empty string — must exit non-zero with the `gh`
stub never called, so the test proves the constraint fires before the request rather than
after the URL is addressed, and two further cases prove it does not fire on the
`workflow_dispatch` and `push` paths that never build that URL.

The `ci-eligibility` composite action records the exception this creates in its own
contract: it documents failing OPEN on status uncertainty, and an invalid `head-sha` now
fails it CLOSED. External consumers passing a branch name or an abbreviated SHA will
hard-fail.

ADR 0194 also records the residual this change does not close: `2>/dev/null || echo 0` on
the same compare call still turns a genuine API outage into `behind=0` and proceeds.
Tracked as #1476.


Re-review round 5 closed two more fail-opens in the negated-branch anchor, neither of which
the round-4 "this is the only fail-OPEN in that class" sentence admitted. A fatal statement
nested in a `while`/`for`/`until`/`select` body or a `case` arm counted as a statement of
the `then` arm, because the depth counter tracked only `if`/`fi` — so a loop that runs zero
times, or a `case` that matches nothing, reached the use with an unchecked value.
`branch_events` now tracks `do`/`done` and `case`/`esac` too. This is not the deleted
loop-depth count returning: it never licenses `continue`/`break`, and every fixture in the
file, the real site included, keeps its previous verdict except the shapes it is meant to
flip. That is an observation over the fixtures, not a proof that a depth counter can only
reject more.

The second is the structural pass being per-line. It starts every physical line unquoted,
so a here-document body, and a string continued onto the next line, read as ordinary
commands rather than blanking — a bare `if` in either, inside the `else` arm, inflated the
depth and made a use sitting below `fi` read as protected. Modelling those regions is shell
parsing; detecting them is not, so the walk now declines on a here-document introducer or an
unclosed data span instead. That is fail-closed, and costs a guard whose `else` arm
legitimately contains a here-document. Probing the first form of that detection found two
near-misses of its own — an introducer blanked away inside an unclosed `$(`, and a delimiter
not beginning with a letter — which are closed and pinned as well.

Round 6 stops patching that detection and inverts its default instead (#1489, ADR 0194).
Each of rounds 1 through 5 closed the previous round's fail-open by naming one more
construct the walk must refuse, and each shipped a new one inside the same mechanism: a
subshell `( exit 1 ) || echo`, a function definition `cleanup() { exit 1; }`, a
backgrounded group `{ exit 1; } &` and an expansion opened on one record and closed on a
later one all reached the fatal statement and read as a terminating arm. Enumerating the
bypass forms is unwinnable, so the arm walk no longer accepts a record it has not
accounted for. `arm_record_is_modelled` recognizes the shapes this model does represent --
no here-document introducer, no data span left open at the record's end, no `&` outside
`&&`/`>&`/`<&`/`&>`, at most one `{` and braces balanced, and a parenthesis only where an
open `case` makes it an arm label (Round 9 replaces that last clause with arm POSITION) --
and every other record ENDS the walk as a reject.
Unmodelled structure can no longer produce an accept. Its measured cost on this repository
is none: the four pinned figures -- 77 interpolations, 144 workflows, 14 sites, 11
allowlist entries -- are unchanged, because the one live guard it initially rejected,
`scripts/privileged-merge-conformance.sh:327`, was recovered by proving the specific `case`
arm-label shape rather than by widening the allowlist. Each of the six rules is pinned by a
fixture that no other rule rejects, so none is decorative.

Every new shape is pinned with a control that moves the same fatal statement to the arm's
top level and must stay live, so a `dead` verdict cannot pass for the wrong reason.

Two ADR 0194 measurements were corrected rather than restated. "No `.py` file contains a
`|| { … }`" was false, and so is the narrower "no `.py` line's structural tail is `|| {`":
`scripts/gen-node-ci-protected.py:778` does end that way structurally, because the quote
model has no account of Python's `\"` escapes. What holds is that no such `.py` record is
accepted by `brace_body_is_fatal` — a fact about the CONTENT of those three emitted-shell
string literals rather than about `.py`, so an edit to `scripts/gen-node-ci-protected.py`
can move it. The denominator is **removed**, not adjudicated: three independent derivations
produced two values, and a fourth here produces a third, so it does not belong in a durable
record whichever is right. Every claim about it is removed with it.

The numerator is now removed on the same rule, rather than corrected a third time. The
predicate it was published with — "accepted fatal `|| { … }` bodies carrying a `>&2`" —
never pinned its unit (the accepted body, the record `logical_lines` emits, or the `|| {`
occurrence) or the scope of the `>&2` (inside the accepted body, or anywhere on the record),
and independent derivations reading those axes differently disagreed. ADR 0194 already
states the standard that settles it: a figure returns only with a predicate that pins its
unit and its scope. What the fail-closed entry rests on is a property, not a count — this
repository writes its errors to stderr inside the failure branch — and it is checkable by
reading the two lines cited above. Only `144`, the size of the scan's own file set, is
stated.

## Round 7

The arm-label exception round 6 added leaked more than it claimed, and closing that is a
structural change rather than a seventh construct on a list. A record accepted as a `case`
arm pattern label was still handed to `branch_events`, which reads each `;`-part's FIRST
WORD. A label whose first word happened to be a depth keyword — `do )`, `if )`, `case )`,
or an alternation such as `do|while )` — therefore emitted a spurious opening event, the
guarded construct's own `fi` never fired at relative depth 0, the walk ran out of records
with the use still reading as inside the `else` extent, and a guard that protects nothing
read as live. All four spellings are ACCEPTed by the code this round changes, against a file
`bash -n` accepts; renaming the same label `aa )` REJECTs, and `do)` without the space
REJECTs, so the vector is the spaced and alternation spellings specifically.

The fix is that a record admitted as an arm label is now INERT: `arm_record_is_case_label`
is the shape, and the walk skips such a record entirely instead of reading a command out of
it. The exception now grants exactly the one property it claims — this record is a modelled
case arm label — and nothing else. Adding `do`/`if`/`case`/… to a set of words a label may
not begin with would have been round 8 of the same cycle; the label's first word is not a
command at all, which is why the structural answer is available here. Its cost is nil: the
four pinned figures are unchanged, every live control still ACCEPTs, and
`scripts/privileged-merge-conformance.sh:327` — whose real consumer is the `slice`-mode
`sha_constrained` path over its `contents/…?ref=$caller_contract_sha` reads — is unaffected,
its three arm labels passing through inert.

Two statements in the same paragraph were wrong and are corrected rather than reworded.
`( exit 1 )` DOES match the arm-label shape; the sentence claiming it does not was
contradicted by the fixture added beside it in the same commit. The effect was fail-closed,
but a wrong stated reason is what the rounds before this one shipped. And the terminator the
shape listed named `;&` and `;;&`, which the model never accepts: a record carrying either
has a bare `&` and declines at the `&` rule first, so listing them made the model claim a
spelling it refuses. The terminator is narrowed to `;;`, which is a narrowing of the CLAIM
and not of the behavior — every `;&`/`;;&` record was rejected before and is rejected now.

One claim is narrowed rather than defended. The header said anything outside the enumerated
shapes lands on the rejecting side by default. That frontier is LEXICAL: what the walk
refuses is a record whose TEXT carries structure the depth model cannot pair, so a record
that reads as an ordinary simple command is walked past — which is the job. A command that
builds control flow at run time is therefore outside the model and is not refused. `eval
"fi"` is read as a call to `eval` and walked past, before this change and after it. It is
not defended against and does not need to be — bash reports a syntax error and `eval`
returns 2, so it closes nothing — but the residual set, "records whose run-time effect is
not their text", is now named in the header instead of being covered by a sentence wider
than the code.

> **Superseded by Round 9.** The narrowing in this paragraph was the fourth revision of the
> same sentence and is false too: `case "$b" in y)` is inside the lexical frontier, its
> run-time effect *is* its text, and it was accepted and unrepresented anyway. The
> completeness claim is deleted rather than narrowed a fifth time.

## Round 9

Rounds 7 and 8 proved an arm label wherever *some* `case` was open. An ordinary nested
`case` written on one line — `case "$b" in y)` — matches the arm-label shape, so round 8's
inertness dropped its opening `case` event. The guarded construct's own `fi` then fired one
level too shallow, the walk ran out of records with `in_then=0`, and a guard whose `then`
arm only counts a failure and falls through read as LIVE, in both `whole` and `slice` mode,
against a file `bash -n` accepts. Splitting the same nested `case` over two lines REJECTs,
which is how the label reading is isolated as the sole cause.
`.github/workflows/gate-rearm.yml` writes that spelling, so it is repository content.

Two changes, and neither is a ninth shape rule.

*Arm position.* `case … in` and `;;` are the only two places bash itself parses a word list
ending in `)` as a pattern; everywhere else in an arm a `)` opens a group. The walk now
tracks that position — a `case` event or a record ending in `;;` enters it, consuming a
label or an `esac` leaves it — and a `)`-bearing record read outside it declines, which is
the inverted default and a REJECT. This is parser state rather than shape matching, and it
is strictly narrower than the old `case_depth > 0` test: measured over the scanned files it
admits nothing new and withdraws five records in `scripts/gen-container-deployment.sh`, none
of which is a case label.

*An inert record emits nothing.* `arm_record_is_case_label` now also requires the record to
produce no `branch_events` at all, so the walk cannot discard an event by calling a record
inert. This is the property the header states and `arm_inertness_emits_no_events` tests over
the scan's own 144 files rather than over a fixture list; the corpus contains five records
that are arm-label-shaped and do emit events, so deleting the requirement turns the suite
red on real repository content. It closes the vector a second time, and it retires round 7's
`do )` / `if )` / `case )` / `do|while )` exception: those now decline. That is the measured
price and it is recorded as a fail-CLOSED false negative rather than hidden.

The reason round 7 gave for needing no statement rule was false and is deleted, not
repaired: "`case` raises `d` and `case_depth` together and `esac` lowers both, so
`case_depth > 0` implies `d > 0`". `fi` and `done` lower `d` without lowering `case_depth`,
and `branch_events` reads `probe || { if q; then a; fi; }` as a bare `fi` — the `{`-part's
first word is `{`, never `if` — so `d` reaches 0 with a `case` still open and a label is
read at relative depth 0. Nothing needs the claim: an inert record contributes no statement
and no event, so the depth it is read at grants it nothing. The skip is still load-bearing
for the statement half, and until this round nothing pinned it: `fail )` is a legal arm
label that `arm_statement_is_fatal` calls terminating, and deleting the skip entirely left
every other assertion in this file green.

Cost, measured rather than asserted: the four published figures are unchanged — 77 ref
interpolations (21 Python) across 144 files, 14 sites covered by 11 allowlist entries — and
`scripts/privileged-merge-conformance.sh` still ACCEPTs in `slice` mode at `:331`, `:336`
and `:340`, `:340` sitting past all three now-inert arm labels. `144` is now asserted as
`SCANNED_FILES` beside `RECOGNIZED_REF_SITES=77`, because it was reported in the PASS line
and repeated in ADR 0194 while nothing pinned it; its breakdown re-derives as 57 `.py` + 38
`.sh` + 49 `.yml` only after the `*.test.sh`/`*.test.py`/`*_test.py` exclusion, whose naive
per-extension totals are 144, 157 and 49.

## Round 10

Rounds 5 through 9 each patched the arm-label rule and each shipped a new fail-open. This
round leaves that rule alone and fixes the layer under it: `branch_events` read only the
*first* word of each `;`/`&&`/`||`/`|`/`&`-separated part, so every compound opener that
bash accepts in a later command position was invisible while its closer — which bash
requires to be first-word — was not. Three repository-legal spellings dropped one level of
depth each: `probe || { if q; then a; fi; }` read `fi`, `if a; then if b; then c; fi; fi`
read `if fi fi`, and `time if q; then a; fi` read `fi`. A negative guard whose `then` arm
terminates below such a record then had its own `fi` fire one level too shallow and read
LIVE in both `whole` and `slice` mode, against files `bash -n` accepts — the same class of
fail-open as round 9, reached without touching a label.

`branch_events` now scans *every* command-position word of a part, not just the first, and
the fix is stated as bash's grammar rather than as a shape list. Command position restarts
after `{`, `!`, `time`, `time -p`, `time --`, `coproc`, and the list-introducing reserved
words `if`, `elif`, `then`, `else`, `do`, `while`, `until`; an unmatched leading `(` also
restarts it, and a `)` that closes the word ends the restart. Each member is pinned by
`branch_events_case`, which asserts the exact event stream *and* `bash -n` on the record, so
a pin cannot drift into asserting the reading of a program bash would reject. The stopping
points are pinned too: `case`, `for`, `select`, `function` and `in` do not restart command
position, a reserved word in argument position (`echo if a then b fi`) or inside a test
(`[ "$x" = if ]`) emits nothing, and `X=1 if …` and `>/dev/null if …` are asserted illegal
rather than assumed inert, because an assignment or redirection prefix cannot precede a
reserved word. `case` gets one piece of state rather than an exception: the scan skips from
`case` to the `)` ending its first pattern, so `case $x in a) if q; then b; fi ;; esac`
reads `case if fi esac` and stays balanced.

The mutation matrix over the restart set kills all sixteen mutants; the `if` token survived
the first pass and is now pinned by `if if a; then b; fi; then c; fi`, an `if` whose
condition is itself a compound list.

Two claims are deleted rather than narrowed. The directional sufficiency argument — that a
dropped event can only make the walk run out of records, so the failure is one-sided —
is false for `else`/`elif`, and naming both exits does not repair it: the walk's *other*
exit, `fi` at depth 0 returning `arm_terminates`, is a genuine fail-open when an `else`
emission is dropped, as `if ! guard; then echo warn; else exit 1; fi` demonstrates. The
argument is gone from both places it appeared; the stricter property it was decorating
stands on its own. And the surviving-mutant note is deleted because the mutant no longer
survives: `( probe )` is arm-label-shaped, legal directly after `esac`, emits nothing and
is *not* read as fatal, and the mechanism that distinguishes it is `expecting_label=0`
turning an `arm_record_is_modelled` REJECT into an inert skip — not the statement check
that earlier rounds were looking at. It is pinned now, so nothing on this branch is carried
as known-unproven.

`arm_label_is_inert_violations` is tautological on unmutated code — `arm_record_is_case_label`
already requires emit-nothing — and its comment now says so: it is a mutation detector, and
the separate witness floor of five corpus records is what keeps it from being vacuous.

The PASS line said "144 workflows"; 144 is files across three globs, of which 49 are
workflows. It says files.

Cost: none measured. All four published figures are unchanged — 77 ref interpolations (21
Python), 144 files, 14 allowlisted sites, 11 allowlist entries — the witness floor is still
five records on the same five sites, and `scripts/privileged-merge-conformance.sh` is
untouched in this round's delta. Fixing the event stream widens no reading: every new event
is one bash already executes, so a record that gained an opener also had its matching closer
counted all along, and the balance it restores can only make the walk stricter.

Round 11 stops patching tokens and inverts the event stream itself. Round 10 argued its
restart set was closed "because it is read off that grammar rather than collected from
counterexamples"; `coproc` was in the set but `coproc`'s *optional NAME* was not, so
`coproc c if q; then` emitted no events where the unnamed `coproc if q; then` emitted `if`,
and only the unnamed spelling was pinned. End to end on bash 5.2.21, `bash -n` clean and
clean through every existing filter, `if ! <hex guard>; then` / `coproc c if q; then` /
`exit 1` / `fi` / `fi` / `gh api …` read LIVE in both `whole` and `slice` mode, went DEAD on
deleting the two characters `c `, and when executed printed `REACHED use with [not-a-sha]`
because the `exit 1` runs in the coprocess.

The generator of that hole, and of the nine before it, is that `branch_events` was
permissive: a command-position construct it had no rule for was scanned past in silence, so
unmodelled and absent produced the same empty stream and absent reads as safe. The stream now
has the same inverted default `arm_record_is_modelled` has had since round 6. Command-position
classification is total over bash's reserved words — the closed set bash publishes as
`compgen -k` — and a reserved word the walk does not positively classify is emitted as
`decline:<word>`, which `negated_branch_dominates` reads *before* any event the same record
emitted and rejects on. `branch_events_classifies_every_reserved_word` asserts the four
buckets partition `compgen -k` exactly, so a word bash adds or an edit drops reddens there
instead of rejoining a permissive default; it replaces a prose closure argument with a
checkable one. `coproc` is declined rather than modelled, because modelling `coproc [NAME]
command` is one more token rule of the kind that produced ten rounds of holes.

Two things fall out instead of being special-cased. Grouping punctuation is now counted
rather than stripped, so a doubled `((`/`))` declines: stripping it had manufactured
command-position words out of arithmetic, and `if (( fi > 0 )); then a; fi` read `if fi fi`
— a spurious closer firing the guarded return one level too shallow, caught only by the
record-level parenthesis filter. And a declining record is visibly declined in the stream
rather than silently clean, which is the difference between the walk abstaining and the walk
clearing something.

Cost, measured rather than assumed: across 144 files and 33,196 logical records, 132 records
now carry a decline and all 132 were *already* refused by `arm_record_is_modelled`'s
parenthesis rule — they are embedded `jq` and `awk` program bodies. The corpus contains no
`coproc`. No site needed a new allowlist entry, all four published figures are unchanged
again (77 ref interpolations, 21 of them Python, 144 files, 14 allowlisted sites, 11
allowlist entries), and the corpus witness floor still measures five records.
`stream_only_declines` pins that zero — it counts only declines that cost the anchor reach it
previously had — with a floor requiring at least one declining record so the zero is not
vacuous. A sound prefilter derived from the decline bucket keeps the suite near its previous
runtime.

One claim is deleted rather than narrowed: the pinned assertion that `coproc` is a restart,
and therefore that the `if` after an unnamed `coproc` is counted. The walk no longer counts
openers inside a `coproc`'s command at all. That loss is one-directional — the record now
rejects instead of being modelled — so it costs reach, never safety, and both spellings are
pinned now, because pinning only the unnamed one is what let round 10's argument stand. The
decision is recorded in ADR 0196, which names what the inversion does not buy: it is not a
proof of correctness against bash's parser, and `compgen -k` totality proves only that no
reserved word is missing from the classification, not that each is in the right bucket.

ADR 0194's Consequences section also records the resolution of the residual it named. That
ADR flagged the behind-count compare's `2>/dev/null || echo 0` as a route into `behind=0`
that its own encoding fix did not close, and tracked it as #1476. #1476 is now closed: PR
#1494 replaced the swallow with a helper that returns non-zero on a failed request, retries,
and holds with an `::error::` when the compare API is still unanswerable, and ADR 0195
generalized the rule that an indeterminate answer is not a permissive one. The note is
written here because ADR 0194 does not exist on `main` — this branch introduces it — so
#1494 could not have written it from its own branch. It records an outcome and reverses
nothing: a decided ADR is superseded by a successor, never edited to reverse.

Two limits of the encoding gate are now stated in its own header rather than left to be
rediscovered. First, its acceptance is positional: it requires an encoding assignment above
the use within the block, and does not track the value that reaches the URL, so inserting
`base_ref_path="$base_ref"` between the `@uri` line and the `gh api` line leaves the ref
fully unencoded while the gate still exits 0. The shipped workflow is correct — that was
verified by construction against the live compare call — but the gate must not be cited as
establishing encoding for a variable assigned more than once. Tracked as #1508.

Second, and found while attempting to harden the opposite direction, the recognizer accepts
the encoding only as the entire assignment: appending `|| return 1` to it makes the gate fail
the very line it exists to bless. The assignment is therefore deliberately left bare. It
still fails closed, since an empty encoding yields a `compare/...` path that 404s, so `gh api`
exits non-zero and the `|| return 1` on that same line fires; the `[[ =~ ^[0-9]+$ ]]` guard below
is the second net, reached only when `gh api` exits 0 with a non-numeric body. Guarding the
clobber does not narrow the ceiling either: an `if [ -z ... ]` arm and the `[ -z ... ] &&` form
were each measured at exit 0 as well, so no second-assignment form is known to be caught.

Also corrected here: the merge commit's message claimed that a future rebase resolving toward
this branch's side — reinstating the `|| echo 0` fail-open — would be "caught by nothing".
That is wrong, and understating live coverage on a privileged merge path invites redundant
scaffolding later. Reinstating the swallow inside the command substitution makes
`scripts/ci-gate/freshness.test.sh` exit 1 with 3 `FAIL -` assertions (`indeterminate compare
(error) did not hold`, `compare attempt count is not exactly 3`, `retry did not stop on the
first answer`), and it is registered at `scripts/actions-ci-groups.tsv:82`, so it runs.

That correction is bounded to the placement it names. Moving the same swallow *outside* the
command substitution -- `raw="$(gh api ... 2>/dev/null)" || echo 0` -- leaves `freshness.test.sh`
at exit 0 with 0 `FAIL -`: it is caught by no test. It is not a live fail-open, because `echo 0`
writes to stdout rather than to `raw` and the numeric guard on the next line still returns 1, but
it is covered only at runtime, not by the suite. So coverage is not symmetric; the inside form is
caught, the outside placement is not.
