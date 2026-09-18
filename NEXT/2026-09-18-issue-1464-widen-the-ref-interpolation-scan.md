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

A cited guard is checked for being live, not merely present. `grep -F` alone found the
text anywhere in the file, so commenting the guard out or appending `|| true` left this
gate green — the same rot one level up. A citing entry now requires the pinned text on a
line that is not commented out ahead of it and does not swallow its own failure there. It
is a line-level anchor and says so: a guard moved into a branch that never runs still
satisfies it.

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

