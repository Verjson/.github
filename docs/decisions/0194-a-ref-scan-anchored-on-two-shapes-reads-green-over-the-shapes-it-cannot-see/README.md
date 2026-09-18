# 0194 — A ref-encoding scan anchored on two shapes reads green over every shape it cannot see

- **Date:** 2026-09-18
- **Status:** Accepted
- **Related:** [ADR 0192](../0192-encode-adopter-ref-names-before-they-reach-a-url/README.md), [ADR 0184](../0184-merge-gates-assert-execution-not-absence-of-red/README.md)
- **Issues:** [#1464](https://github.com/Verjson/.github/issues/1464), [#1470](https://github.com/Verjson/.github/issues/1470), [#1476](https://github.com/Verjson/.github/issues/1476)

## Context

ADR 0192 decided that every adopter- or contributor-controlled ref name is encoded for the
position it occupies before it reaches a `gh api` URL. `scripts/ci-gate/default-branch-uri-encoding.test.sh`
is the gate that enforces it. Issue #1464 reports that the gate recognizes only two syntactic
shapes — a `?ref=` query value and a `git/refs/heads/` path segment — so a ref reaching a URL
through any other shape is unenforced while the suite prints `PASS`.

That was measured rather than assumed before anything was widened. A broad grep over tracked
workflows and non-test scripts produced 79 candidate ref-bearing lines; 44 of them were
invisible to the recognizer, yielding **42 sites it never judged**. Recognized sites go from
**35 to 77** under this change. The unseen shapes were `commits/`, `git/commits/`,
`git/trees/`, `git/tags/`, `branches/`, `rules/branches/`, both operands of a `compare/`
range, `${braced}` shell interpolation, and the Python `{quote(...)}` equivalents of all of
them.

One of the newly visible sites is on the merge-authorization path, which is why this is an
ADR rather than only a PR.

### The unencoded base ref in `ai-review-merge.yml` fails **open**

The freshness step asked the compare API how far behind the base a PR head is:

```
behind="$(gh api "repos/$REPO/compare/$base_ref...$head_sha" --jq '.behind_by' 2>/dev/null || echo 0)"
```

`$base_ref` arrives from `jq -r '.baseRefName // "the base branch"'` — adopter-controlled and
unencoded. The comment above it asserted that putting the head **SHA** on the right meant "a
slash in the head branch name can't confuse the `...`-path", and said nothing about the left
operand being a branch name at all.

Two things follow, and the order matters:

- **`/` was never the vulnerable character.** Measured against the live API on this
  repository with the slash-bearing branch `fix/merge-predicate-execution-evidence`: the
  `compare`, `commits`, and `branches` endpoints resolve identically for a literal `/` and for
  `%2F`. So the comment named a risk that did not exist, and named it in place of the one that
  did.
- **A git-legal, URL-significant character is the real one.** `#` and `%` pass
  `git check-ref-format` and are not `/`. A base ref carrying one misresolves this URL.

The consequence of misresolution is the part that makes it sensitive. The call is wrapped in
`2>/dev/null || echo 0`. A misresolved request 404s, `behind` becomes `0`, the `update-branch`
branch is skipped, and the step falls through to `out proceed true`. The gate therefore
**merges on a review performed against a stale base** — it does not hold, error, or warn. A
guard that fails open is worse than an absent one, because the green result is read as
evidence.

## Decision

**The left operand is percent-encoded as a path segment** — `@uri` with no `gsub` back to
`/`, per ADR 0192's position rule — before it is interpolated:

```
base_ref_path="$(jq -rn --arg base_ref "$base_ref" '$base_ref|@uri')"
behind="$(gh api "repos/$REPO/compare/$base_ref_path...$head_sha" --jq '.behind_by' 2>/dev/null || echo 0)"
```

**The gate is widened to the measured miss, not to a guess.** Each added shape carries a
fixture in a recognizer self-test that the scan misses before the anchor is added and catches
after; reverting an anchor names the blind shape in the failure text rather than failing
somewhere downstream.

**A site the scan flags is fixed or allowlisted with a stated reason — never accommodated by
weakening the recognizer.** Sites whose value is a 40-hex object name are proved by their
constraint, and each allowlist entry pins the literal guard text it cites, so deleting that
guard reddens this gate rather than silently converting a proof into an unexamined pass. The
recognized-site count is asserted, not merely printed, because a refactor that moves an
interpolation out of a recognized shape otherwise lowers coverage silently while still
printing `PASS`.

**The remaining ceiling is stated in the test's header** rather than claimed closed: non-brace
Python construction, Python embedded in workflow YAML, shell positional parameters,
interpolations split across source lines, and path segments outside the anchored set.

## Consequences

**No ref that previously worked changes verdict.** This rests on the live-endpoint
measurement above, not on inference: literal `/` and `%2F` resolve identically on the
`compare` endpoint for a real slash-bearing branch in this repository. What changes is a ref
containing a URL-significant character, which previously produced a silent `behind=0`.

**The `rules/branches/` encoding question is recorded, not guessed.** The org's rulesets
target `~DEFAULT_BRANCH` and `refs/heads/develop`, so no live measurement discriminates
literal `/` from `%2F` there — the endpoint returned `0` rules for both forms. Four sites
build that path (`gate_coverage_audit.py`, `required-checks-audit.sh`,
`required-checks-rollout.sh`, `scripts/privileged-merge-conformance.sh`) while
`assert-mergeable-head.sh` and `scripts/ci-gate/verify-arm-receipt.sh` keep the slash
literal. Guessing would encode a mismatch into a merge gate. The conflict is allowlisted with
the disagreement recorded in the entry and tracked in #1470.

**Adopters must regenerate at a new contract SHA.** `scripts/container_deployment_review_producer.py`
gains boundary validation on its commit arguments, and it is digest-pinned by
`scripts/gen-container-deployment.sh`, so the container-deployment contract digest moves.

**The compare call still fails open on an outage, and that is NOT closed here.** The
encoding fixes the *misresolution* route into `behind=0`. It does not touch
`2>/dev/null || echo 0`, so a genuine API failure — rate limit, outage, a token that lost
its scope — still yields `behind=0`, skips the branch update, and proceeds. By this ADR's
own argument that a guard which fails open is worse than an absent one, that residual is
named rather than left implicit: the swallow is deliberate today and changing it changes
merge-gate behavior for every PR, so it is separate work, tracked as
[#1476](https://github.com/Verjson/.github/issues/1476). Read this ADR as closing the
encoding route into the fail-open path, not the path itself.

**The guard pin is a command-level anchor, and it allow-lists failure, not swallowing.**
This claim has now been corrected three times, which is itself the lesson. The first version
said a cited guard "still fails"; the second narrowed that to "does not swallow its own
failure on that line"; the third replaced the denylist with an allow-list and claimed
"enumerating the one acceptable shape fails closed, so a swallowing form nobody has written
yet reddens rather than passing". Each was falsified by an independent re-review.

The first two failed because a denylist of four swallowing literals (`|| true`, `|| :`,
`||true`, `or True`) let six further forms — `||:`, `|| { :; }`, `|| echo skipped`, `| cat`,
a trailing `&`, and `|| exit 0` — keep the gate green against `gate-rearm.yml:168`, and
because a line-level anchor could not see the shape this PR itself introduced, where
`node-ci.yml` writes the guard on one line and its `|| { …; exit 1; }` on the next.

The third failed for a more interesting reason, and it is the reason this paragraph is now
written the way it is. The allow-list's brace alternative matched the fatal action as a
**substring of the brace body**, with no notion of command position — which is a denylist
wearing an allow-list's clothes. Mutating the real guard at `node-ci.yml:437`, the control
`|| true` reddened, and seven forms did not:

| tail | why it swallows |
| --- | --- |
| `\|\| { echo "would exit 1 here"; }` | `exit 1` matched inside a string, never executed |
| `\|\| { ( exit 1 ); }` | exits the subshell only |
| `\|\| { false && exit 1; }` | unreachable |
| `\|\| { cat <<EOF` / `exit 1` / `EOF` / `}` | printed by a here-document, never run |
| `\|\| exit 256` | wraps to a 0 wait status |
| `\|\| return 256` | wraps to a 0 wait status |
| `\|\| continue` / `\|\| break` with no enclosing loop | bash warns; execution carries on |

So the anchor now reasons about command position rather than substring presence. It joins
continuations — a trailing `\`, a trailing `&&`/`||`/`|`, and a multi-line `|| { … }` branch
are one command, with the branch closed by brace **depth** so a closer carrying a tail
(`} >&2`) cannot buffer the rest of the file into one line. It then blanks quoted spans,
`#` comments, `${…}`, `$(…)` and `(…)` subshells, and requires what follows the final
`&&`/`||` to be one of: `exit N`/`return N` for N in **1–255**; `fail`/`fault`/`die`/`abort
…`; `continue`/`break` **inside a loop**, established by a lexical `do`/`done` count that
must hold together or else report zero everywhere; a `{ … }` whose body is **flat** (no
nested group, no redirection operator) and one of whose top-level statements is **exactly**
one of those actions; or an empty tail, which under `set -euo pipefail` means the guard's own
status is the command's. Every form in the table above, the six pre-existing swallows, the
continuation-line `|| true`, and the accepted shapes are permanent regression cases in
`scripts/ci-gate/default-branch-uri-encoding.test.sh`, and the six new ones were each
verified by mutating `node-ci.yml:437` in a real worktree and observing exit 1.

**What the corrected claim still does NOT cover.** Stated plainly rather than implied away,
and split by which direction the error runs.

*Fail-closed* — these read a live guard as disarmed, so they cost false positives, never
coverage:

- `exit 300` does leave the guard (status 44) but is rejected; the 1–255 bound is easier to
  state and to trust than "any N that is not a multiple of 256".
- A nested command group, or a redirection operator, in a brace body is not flattened.
- An action reached only through a `&&`/`||` chain inside the body is not unconditionally
  reached. This anchor does not evaluate conditions: it cannot tell `{ false && exit 1; }`
  from `{ [ -n "$x" ] && exit 1; }`, and reads both as disarmed.
- The structural pass is a lexical scan, not a shell parser. It models quotes, backticks,
  backslashes, `${…}`, `$(…)` and word-position `#` — not here-documents, `case` patterns,
  or quoting nested inside `$(…)`. Where it is unsure it blanks, which reads as not fatal.
- The `do`/`done` count is lexical too, and `do` must additionally be loop-shaped: the prose
  at `node-ci.yml:345` ("…not masked secrets; do not put credentials") otherwise raised the
  loop depth for that entire file, which is how the out-of-loop `|| continue` bypass was
  found. An unbalanced or negative count reports depth 0 everywhere.

*Fail-open* — these satisfy the pin while the guard no longer guards, and are the honest
ceiling of a command-level anchor:

- **Python guards get the comment check and nothing more.** Every cited Python guard is a
  sub-expression of an `if … is None:` test or a `require(…)` call, and there is no single
  tail shape that means "this raises" without parsing the file. Five of the eleven allowlist
  entries are in this weaker class, as is the shell-shaped proof that is really a pinned
  assertion *string* inside a `.py` list. For those the pin means only "the cited check is
  still written". It does not mean the check still rejects anything, and a green run must
  not be read as though it did. The `or True` denylist entry that used to be here was
  dropped rather than kept, because a one-entry denylist reads like protection while
  catching nothing adjacent to it (`or 1`, `or (lambda: True)()`, a `require` redefined
  above); the gap is stated instead of papered over.
- **A guard moved into a branch that never executes** still satisfies the pin. This is
  reachability analysis, which the anchor does not do.
- **A guard made vacuous** by changing the value it tests, rather than the test itself.
- **A terminating word redefined as a no-op.** The helper names are allow-listed by name
  with no proof that they terminate, and bash lets `exit` and `return` be shadowed by a
  function too — so this covers the whole allow-list, not just `fault`.
- **The pinned literal matched inside a string.** The literal search runs over raw text, so
  deleting a guard and leaving its text in an `echo` satisfies the pin.

Read the shell pin as "the cited text is still written outside a comment, and the
continuation immediately following it is one of the shapes above". Do not read it as "the
guard still fails". The test header states the same boundary in the same words. A pin that
overstates its own reach is the defect this ADR is about, one level up — which is what all
three earlier versions of this paragraph were.

**The gate can still be outgrown.** The stated ceiling is the honest boundary: it says what
this scan recognizes, not that every ref in the repository is covered. It now names
composite actions explicitly, because `scanned` covers `.github/workflows/*.yml`,
`scripts/*.sh` and `scripts/*.py` and not `.github/actions/*/action.yml` — so the
adopter-facing `commits/${HEAD_SHA}/status` read in `.github/actions/ci-eligibility/action.yml`
is never judged by this gate. It is covered indirectly, by the byte-parity assertion at
`scripts/ci-gate/ci-eligibility.test.sh:55-63` between that composite script and node-ci's
inline copy, and that indirection holds only while the parity assertion does. Widening it again is
the same procedure — measure the miss first.

## Related

- Issue #1464 — the reported anchor-narrowness defect
- Issue #1470 — the unresolved `rules/branches/` encoding disagreement
- PR #1469 — the implementation
- Issue #1476 — the residual fail-open swallow on the same compare call
- ADR 0192 — the position-dependent encoding rule this gate enforces
