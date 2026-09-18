# 0194 — A ref-encoding scan anchored on two shapes reads green over every shape it cannot see

- **Date:** 2026-09-18
- **Status:** Accepted
- **Related:** [ADR 0192](../0192-encode-adopter-ref-names-before-they-reach-a-url/README.md), [ADR 0184](../0184-merge-gates-assert-execution-not-absence-of-red/README.md)
- **Issues:** [#1464](https://github.com/Verjson/.github/issues/1464), [#1470](https://github.com/Verjson/.github/issues/1470)

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

**The gate can still be outgrown.** The stated ceiling is the honest boundary: it says what
this scan recognizes, not that every ref in the repository is covered. Widening it again is
the same procedure — measure the miss first.

## Related

- Issue #1464 — the reported anchor-narrowness defect
- Issue #1470 — the unresolved `rules/branches/` encoding disagreement
- PR #1469 — the implementation
- ADR 0192 — the position-dependent encoding rule this gate enforces
