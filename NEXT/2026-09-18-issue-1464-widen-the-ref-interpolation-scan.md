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

Sixteen further sites that the scan cannot prove at the point of use are now named in an
explicit `REF_SITE_ALLOWLIST` with a reason each, in two classes: a 40-hex object name
whose constraint lives in another step, function, or caller; and a ref name carrying a
stated non-encoding guard. A stale entry fails the test, so the list cannot rot into a
silent hole. `scripts/assert-mergeable-head.sh` is allowlisted with an unresolved
conflict recorded at the entry: it encodes a `rules/branches/` segment in the query form
while three other sites use the path form for the same endpoint. `branches/` and
`commits/` were measured against the live API to accept both forms; `rules/branches/`
could not be settled because no Verjson ruleset targets a slash-bearing ref.

The scan also rejects a file that re-binds `quote` at module scope, which would otherwise
be judged by the stdlib encoder it does not call. A new section 0 measures each anchor
shape against synthetic fixtures, and the file header now states the remaining ceiling:
Python string concatenation and `%`-formatting are a deliberate, stated non-goal, as are
Python embedded in workflow YAML, shell positional parameters, and interpolations split
across source lines.
