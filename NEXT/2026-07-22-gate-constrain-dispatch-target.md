# Merge gate constrains its dispatch target to this org — 2026-07-22

The required org merge gate drives `gh pr view/merge --admin` against
`TARGET_REPO` under `ORG_ADMIN_TOKEN`, and `TARGET_REPO` came from a free-form
`repository` `workflow_dispatch` input — so a dispatcher could aim the
admin-merge machinery at an **arbitrary** org (a cross-repo admin-merge
escalation surface). The `preflight` job now runs an early `target_guard` step
that fails closed unless `TARGET_REPO` is an exact `<owner>/<repo>` whose owner
equals `github.repository_owner`: the default path and sibling-Verjson re-gating
pass, while a foreign owner or a malformed target (`x`, `a/b/c`, `Verjson/`,
empty) rejects the dispatch. The `repository` input is kept (operators can still
re-gate a sibling org repo), just bounded to the org. Downstream single-repo
copies should instead drop the input and pin `TARGET_REPO: ${{ github.repository }}`
(the Tequity ADR-0027 form), as documented in the workflow header. Pinned by
`scripts/ci-gate/dispatch-target-guard.test.sh` (wired into `actions-ci`). See
[ADR 0020](docs/decisions/0020-gate-constrains-dispatch-target-to-org/README.md),
issue #119.
