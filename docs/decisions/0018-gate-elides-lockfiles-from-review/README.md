# 0018 — Merge gate elides generated lockfiles from the AI review payload

- **Date:** 2026-07-22
- **Issue:** Verjson/.github#110
- **Category:** org merge-gate behavior (sensitive class)

## Context

The AI review lane composed its prompt from the complete PR diff
(`gh pr diff … > .ai-review/pr.diff` in the "Prepare bounded review context"
step of `ai-review-merge.yml`). On a PR that changes source **and** refreshes a
lockfile, the generated lockfile dominates the diff. `Verjson/verjson-ai#1` was
10,559 added lines of which `package-lock.json` was 8,007 (76%). The bounded
review budget was consumed reading generated noise before the model could return
a structured verdict, so all three attempts produced no verdict and the gate
failed closed with `ai-review-inconclusive`, demanding manual review of a PR that
was otherwise well within review scope.

The existing docs/manifest fast lane only auto-approves lockfile-**only** diffs;
a mixed PR (source + lockfile) skips that lane and pays the full-diff cost. So
the failure recurs on any substantive PR that also touches a lockfile — a common
shape whenever a dependency is added alongside code.

A lockfile is a derived artifact: a reviewer scrutinizes the manifest
(`package.json`, `Cargo.toml`, `requirements*.txt`, …) and trusts the lock as its
mechanical resolution. Feeding the lock to the model spends budget on content no
reviewer reads line by line.

## Decision

The "Prepare bounded review context" step writes the full diff to
`.ai-review/pr.full.diff` (retained for reference) and hands the model a filtered
`.ai-review/pr.diff` with generated-lockfile sections removed. A single
`LOCK_RE` drives both the filter and the elided-file list; the composed review
prompt — reused verbatim by the escalation pass, so the two never drift — names
the omitted lockfiles and instructs the model that the manifest counterpart IS in
the diff and must still be reviewed.

The elided set is lockfiles only, not manifests:
`package-lock.json`, `npm-shrinkwrap.json`, `pnpm-lock.yaml`, `yarn.lock`,
`bun.lockb`, `Cargo.lock`, `go.sum`, `poetry.lock`, `composer.lock`,
`gradle.lockfile`, `Gemfile.lock`. Manifests (`package.json`, `Cargo.toml`,
`pyproject.toml`, `Chart.yaml`, `Dockerfile`, `values*.yaml`, …) are never
elided — those are exactly what the review must see.

The gate's fail-closed authority is unchanged: only the *review input* shrinks.
Budget, retry count, the three-attempt escalation, the merge recheck, hold/CI/SHA
snapshots, and follow-up filing all behave as before.

### Rejected alternatives

- **Raise the review budget.** Rejected: it pays real money to read generated
  noise on every mixed PR and only defers the ceiling — a large enough lockfile
  churn re-exhausts it.
- **Extend the fast lane to auto-approve mixed source+lockfile PRs.** Rejected:
  the source in such a PR is exactly what needs review; skipping it would be a
  fail-**open** hole.
- **Strip lockfiles at the manifest fast-lane path set.** Rejected: that set
  includes manifests and `Dockerfile`/`values.yaml`, which a reviewer must see;
  elision must target derived locks only.

## Consequences

- A mixed source+lockfile PR now spends its review budget on the source and
  manifest, not the generated lock, removing the dominant cause of no-verdict
  fail-closed runs.
- The full diff remains on disk (`pr.full.diff`) for any step that needs the
  unfiltered change; only the model's payload is filtered.
- The model is explicitly told which locks were omitted and to review the
  manifest, so a malicious hand-edited lockfile is not silently trusted — its
  manifest change is still in scope, and a lock with no manifest change is the
  fast lane's existing lockfile-only case.
- A `scripts/ci-gate/elide-lockfiles.test.sh` extraction test pins `LOCK_RE` and
  both awk programs against synthetic diffs (source kept, manifest kept, locks
  dropped, elided list correct), wired into `actions-ci.yml`, so a future edit
  cannot silently reintroduce the flood or start eliding manifests.

## Sensitive-hunk diff

```diff
-          gh pr diff "$PR_NUMBER" --repo "$TARGET_REPO" > .ai-review/pr.diff
+          gh pr diff "$PR_NUMBER" --repo "$TARGET_REPO" > .ai-review/pr.full.diff
+
+          # Elide generated lockfiles from the review payload. A lockfile is a
+          # derived artifact — the reviewer scrutinizes the manifest
+          # (package.json, Cargo.toml, …), never the machine-generated lock.
+          LOCK_RE='(^|/)(package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|Cargo\.lock|go\.sum|poetry\.lock|composer\.lock|gradle\.lockfile|Gemfile\.lock)$'
+          awk -v re="$LOCK_RE" '
+            /^diff --git / { p = $4; sub(/^b\//, "", p); keep = (p !~ re) }
+            keep
+          ' .ai-review/pr.full.diff > .ai-review/pr.diff
+          elided_lockfiles="$(awk -v re="$LOCK_RE" '
+            /^diff --git / { p = $4; sub(/^b\//, "", p);
+              if (p ~ re) out = out (out == "" ? "" : ", ") p }
+            END { print out }
+          ' .ai-review/pr.full.diff)"
```

See [PR #110](https://github.com/Verjson/.github/issues/110) for the full change.
