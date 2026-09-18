# 0192 — Encode every adopter-controlled ref name before it reaches a `gh api` URL

- **Date:** 2026-09-18
- **Status:** Accepted
- **Related:** [ADR 0184](../0184-merge-gates-assert-execution-not-absence-of-red/README.md), [ADR 0185](../0185-org-contract-distribution/README.md)
- **Issues:** [#1426](https://github.com/Verjson/.github/issues/1426)

## Context

Issue #1426 reported that the adopter default branch reached a `gh api` query string
unencoded. Fixing only that site would have left the class intact: a repository-wide scan
found the same raw interpolation at a dozen sites across the merge-gate scripts and
workflows, including three the issue did not name.

One of them is destructive. `scripts/ci-gate/post-merge-reconcile.sh` interpolated
`$HEAD_REF` — a **contributor-controlled** branch name, arriving from the pull-request event
payload — directly into the path of

```
gh api --method DELETE repos/<repo>/git/refs/heads/$HEAD_REF
```

and swallowed the result with `>/dev/null 2>&1 ||`. A name that re-addressed that path would
delete a ref the step never inspected, and the swallow means nothing would report it.

No exploit is demonstrated, and the precise reason is the point of this record, because
the two plausible readings are both wrong:

- **A literal `..` is not a nameable branch.** `git check-ref-format` rejects it. The API
  *does* normalize that path when it appears literally in a URL — `git/ref/heads/feat/../../heads/main`
  resolves to `refs/heads/main` — but no branch can carry it there.
- **A percent-escaped `..` IS a nameable branch.**
  `git check-ref-format refs/heads/feat/%2e%2e%2f%2e%2e%2fheads%2fmain` exits 0, as do names
  containing `%00` and `#`. But GitHub does not decode-then-normalize: the same request in
  percent-escaped form returns 404 rather than `refs/heads/main`.

So the safety of the unencoded DELETE rested entirely on two properties this code does not
own and never asserted — git's validator forbidding literal `..`, and GitHub declining to
normalize a decoded path. Either could change without a signal at the use site, and the
first review of this change recorded the wrong reason for the right conclusion, which is
how a guard that was never there gets cited as protection.

This is recorded as an ADR because the change hardens a **destructive, irreversible**
operation on the privileged merge path, which our standing guidance treats as a sensitive
class regardless of how small the diff is.

## Decision

Every adopter- or contributor-controlled ref name is encoded before it is interpolated into
a `gh api` URL, using the encoder that matches its position:

- **Path segments** use `@uri` **alone**. Restoring `/` afterwards would let the name
  re-address the endpoint, which on the DELETE is the whole hazard.
- **Query-string values** use `@uri` followed by the `gsub` that restores `/`, because a
  slash is not a delimiter there and encoding it changes the value the API receives.

Choosing the encoder per *position* rather than per *variable* is the load-bearing part. The
two encoders are not interchangeable, and a value that moves from a query to a path — or a
new site that copies the wrong neighbor — reintroduces the defect silently.

## Consequences

**Behavior is preserved for legitimate slashed branch names.** Verified empirically against
the live API rather than assumed: `heads/fix%2Fbar` and `heads/fix/bar` resolve identically
on the ref endpoint, so `feat/foo`-style branches are unaffected by path encoding.

**The reliance on external properties is removed, not merely duplicated.** The encoding
holds whether or not git's validator keeps forbidding literal `..`, and whether or not the
API keeps refusing to normalize a decoded path.

**The swallowed DELETE failure is narrowed rather than closed.** The blanket
`::notice::merged head ref already absent or protected` was not arbitrary: #458 recorded
that a repository with auto-delete-branch-on-merge removes the ref itself, so the DELETE
routinely 404s and branch cleanup must stay housekeeping rather than a verdict. That
contract is preserved — a 404 is still a notice at exit 0. Every *other* status now emits a
`::warning::` carrying gh's actual stderr, because the old text asserted a cause for a
result the step never read, which made a cleanup path that had silently stopped working
indistinguishable from one that had nothing to do. Both directions are mutation-covered:
collapsing the discrimination back to a blanket notice, and widening it to warn on 404,
each redden `post-merge-reconcile.test.sh`.

**Mutation coverage is the regression control.** Twelve mutants, each reverting one site or
swapping one encoder, are killed by the suite. The first review of this change found three
surviving mutants on the recovery path — the tests asserted the selector and inferred the
rest — so the coverage asymmetry, not the encoding, was the real defect.

## Related

- Issue #1426 — the reported single-site defect
- PR #1428 — the implementation
- ADR 0184 — merge gates assert execution, not absence of red
