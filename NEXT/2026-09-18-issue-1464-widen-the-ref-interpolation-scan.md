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
it has to, because 96 fatal `|| { … }` guard bodies across 17 files carry a `>&2` —
`scripts/gen-adr-index.sh:106` and `.github/workflows/node-release.yml:318` are two, read and
verified — and the stricter rule this note used to claim would report every one of them
disarmed. That figure is published with its method, in ADR 0194, because the two it replaces
(67, then 123) were published without one and neither could be reproduced: the universe is
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
open `case` makes it an arm label -- and every other record ENDS the walk as a reject.
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
record whichever is right. Every claim about it is removed with it. `97` is corrected to
`96`: re-derived against both the committed and the working copy of this gate's functions at
this head, under three readings of which `|| {` is meant, it returns 96 across 17 files every
time. Only `96`, `17` and `144` are stated.
