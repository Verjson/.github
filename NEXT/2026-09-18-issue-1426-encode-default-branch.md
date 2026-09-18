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

The default-branch sites are closed as defense in depth: the arm and authorization
steps do validate that branch against `^[A-Za-z0-9._/-]+$` before those reads, which
excludes `#`, `&`, `?`, and `%`. Those guards are general-purpose input checks sitting
up to hundreds of lines from the interpolations they happen to protect, and git permits
a wider set of ref names than they admit, so relaxing one to accept a branch an adopter
legitimately uses would silently re-arm an interpolation with no signal at the use site.

**The `post-merge-reconcile.sh` head-ref site is not one of those, and the distinction
matters because that site is the ref `DELETE`.** `HEAD_REF` arrives as raw
`github.event.pull_request.head.ref` from `ai-post-merge.yml`, which guards
`MERGED_HEAD_SHA`, `EXPECTED_APP_ID`, `EXPECTED_APP_SLUG`, and `check_id` — and not the
head ref. There is no `^[A-Za-z0-9._/-]+$` anywhere on its path, and the literal
`!= "$BASE_REF"` / `!= "$DEFAULT_BRANCH"` comparisons do not constrain its shape.

No exploit is demonstrated, and the reason is worth recording precisely, because the
first two plausible readings are both wrong:

- A literal `..` cannot appear: `git check-ref-format` rejects it, so `feat/../../heads/main`
  is not a nameable branch. The API does normalize that path when it appears literally
  in a URL — `git/ref/heads/feat/../../heads/main` resolves to `refs/heads/main`.
- A percent-escaped `..` **is** a nameable branch —
  `git check-ref-format refs/heads/feat/%2e%2e%2f%2e%2e%2fheads%2fmain` exits 0, and so
  do names containing `%00` and `#`. But the API does not decode-then-normalize: the
  same request percent-escaped returns 404 rather than `refs/heads/main`.

So the safety of the unencoded DELETE rested entirely on two external properties — git's
ref-name validator forbidding literal `..`, and GitHub declining to normalize a decoded
path — neither of which this code stated, tested, or controlled. Encoding makes the
property local and asserted.

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

The `DELETE` in `scripts/ci-gate/post-merge-reconcile.sh` no longer reports every failure
as the same thing. A 404 stays a `::notice::` at exit 0, because #458 established that a
repository with auto-delete-branch-on-merge removes the ref itself and branch cleanup is
housekeeping, never a verdict. Any other status now emits a `::warning::` carrying gh's
actual stderr: the old blanket "already absent or protected" asserted a cause for a result
the step never read, which made a cleanup path that had silently stopped working
indistinguishable from one that had nothing to do.

The decision is recorded in [ADR 0192](../docs/decisions/0192-encode-adopter-ref-names-before-they-reach-a-url/README.md),
because the change hardens a destructive operation on the privileged merge path.
