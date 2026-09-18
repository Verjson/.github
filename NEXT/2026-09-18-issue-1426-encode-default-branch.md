---
date: 2026-09-18
issue: 1426
title: Every gh api URL percent-encodes the adopter ref name it interpolates
impact: patch
---

Hub-privileged automation read adopter repositories through URLs built by string
interpolation of an adopter-controlled ref name — the adopter's default branch, and
in one case a contributor's PR head branch. Every such site now percent-encodes the
name before it reaches the URL:

- query values (`contents/<path>?ref=…`) encode with `@uri` and restore `/`, matching
  the `quote(branch, safe="/")` that #1422 applied on the audit side, in
  `gate-rearm.yml` (compatibility selector and cross-run orphan recovery),
  `ai-privileged-merge.yml`, `scripts/ci-gate/verify-arm-receipt.sh`,
  `scripts/privileged-merge-conformance.sh`, `scripts/required-checks-rollout.sh`,
  and `scripts/required-checks-rollback.sh`;
- path segments (`git/ref/heads/…`) encode with `@uri` and **do not** restore `/`, in
  `ai-privileged-merge.yml`, `scripts/ci-gate/terminal-merge.sh`, and
  `scripts/ci-gate/post-merge-reconcile.sh`. The two encodings are not
  interchangeable: in a query value `/` is an ordinary character the API wants
  literal, while in a path segment a literal `/` re-addresses the resource, so a name
  containing `../..` would leave the endpoint entirely — on
  `post-merge-reconcile.sh` that endpoint is a ref `DELETE`.

Three reads whose value was already constrained to `^[0-9a-f]{40}$` now assert that
constraint at the read itself rather than only at the value's source.

None of this was exploitable: the arm and authorization steps validate the branch
against `^[A-Za-z0-9._/-]+$` before these reads, which excludes `#`, `&`, `?`, and
`%`. It is closed as defense in depth, because those guards are general-purpose input
checks sitting up to hundreds of lines from the interpolations they happen to
protect. Git permits a wider set of ref names than they admit, so relaxing one to
accept a branch an adopter legitimately uses would silently re-arm an interpolation
with no signal at the use site.

`scripts/ci-gate/default-branch-uri-encoding.test.sh` now asserts three separate
things rather than matching one forbidden spelling. It extracts both the
compatibility selector and the cross-run orphan-recovery receipt block out of
`gate-rearm.yml` and executes them against a `release#1&2` default branch, asserting
the recorded API path is `ref=release%231%262` and that `release/2026.09` keeps its
separator literal. It evaluates every encoder expression in the repository against
both fixtures, so a query encoder that drops its `gsub` — or a path encoder that
gains one — fails. And it enumerates **every** `?ref=$…` and `git/ref[s]/heads/$…`
interpolation in the workflows and non-test scripts, requiring each to prove, within
its own function, that its value is either percent-encoded or 40-hex-constrained.
A new unencoded read therefore fails this test instead of needing to be added to a
denylist.
