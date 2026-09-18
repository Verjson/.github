---
date: 2026-09-18
issue: 1426
title: The re-arm gate percent-encodes the adopter default branch it probes
impact: patch
---

`gate-rearm.yml` read the adopter's protected callers through paths built by
string interpolation — `contents/.github/workflows/ai-review-merge.yml?ref=$DEFAULT_BRANCH`
for the compatibility selector, and the `ai-review-label-rearm.yml` blob read in
cross-run orphan recovery. `$DEFAULT_BRANCH` is adopter-controlled text reaching
a query string inside hub-privileged automation. Both sites now encode it with
`@uri`, keeping `/` literal, matching the `quote(branch, safe="/")` that #1422
applied on the audit side.

This was not exploitable: the arm step validates the branch against
`^[A-Za-z0-9._/-]+$` before any of these reads, which excludes `#`, `&`, `?`,
and `%` — the characters that terminate a query or append a parameter. It is
closed as defense in depth, because that guard is a general-purpose input check
sitting hundreds of lines from the interpolations it happens to protect. Git
permits a wider set of ref names than the guard admits, so relaxing it to accept
a branch an adopter legitimately uses would silently re-arm the query-string
path with no signal at the use site. A comment at each encoding records why it
stays despite being redundant today.

`scripts/ci-gate/default-branch-uri-encoding.test.sh` extracts the selector from
the workflow and drives it with a `release#1&2` default branch — the fixture
shape #1422 used — asserting the recorded API path is `ref=release%231%262`, that
a `release/2026.09` branch keeps its separator literal, and that no
`?ref=$DEFAULT_BRANCH` interpolation survives anywhere in the workflow. Removing
either encoding fails it.
