# 0122 — Split release-proposal authority across reusable entrypoints

- **Date:** 2026-08-24
- **Status:** Accepted
- **Issue:** [#1028](https://github.com/Verjson/.github/issues/1028)
- **Category:** release automation and GitHub write authority (sensitive class)
- **Extends:** [ADR 0101](../0101-explicit-release-proposal-autonomy/README.md)

## Context

ADR 0101 requires generated release-proposal callers to choose exactly one
source-controlled authority: `issues: write` for a durable proposal or
`actions: write` for dispatching the existing Release workflow. The generated
callers correctly grant only their selected authority, but both call one
reusable workflow whose single job statically requests both writes.

GitHub caps a called workflow's token to the caller's grants and validates that
call graph before creating a job. A least-privilege caller therefore fails at
workflow startup when the reusable job asks for the other mode's authority.
The workflow never reaches its runtime autonomy check, so a conditional script
cannot repair this admission mismatch. Broadening every caller would make the
permission contract executable but would reverse ADR 0101's visible,
non-widenable autonomy boundary.

## Decision

The canonical contract exposes two reusable workflow entrypoints:

- `release-propose.yml` requests `contents: read` and `issues: write`, then runs
  the engine with the fixed `propose` mode;
- `release-dispatch.yml` requests `contents: read` and `actions: write`, then
  runs the engine with the fixed `dispatch` mode.

Neither reusable workflow accepts an autonomy input. The canonical generator
continues to require `--autonomy propose|dispatch`, but uses that reviewed
source choice to select both the exact reusable workflow path and the one write
permission in the generated caller. The generated artifact remains named
`release-propose.yml` so adopters retain one scheduled proposal surface and do
not need a migration unrelated to authority.

The two entrypoints intentionally duplicate the small checkout, derivation, and
engine-invocation sequence. Extracting that sequence into another remotely
executed action would add a second executable trust boundary merely to remove
YAML repetition. Behavioral contract tests instead require the entrypoints to
remain symmetric except for their fixed mode, workflow identity, and write
permission. Both retain the same repository-wide concurrency group, so a
configuration transition cannot overlap proposal and dispatch effects.

Before rollout, disposable generated callers pinned to the exact reviewed
implementation commit must be admitted by GitHub in both modes. A startup with
at least one created job is the integration boundary; an empty fragment stream
may then finish as a green no-op without exercising either write.

## Consequences

- Each caller can start without receiving the other autonomy's write grant.
- Caller permissions remain an accurate, reviewable statement of the maximum
  effect the scheduled workflow can perform.
- Event data cannot switch modes because neither generated nor reusable
  workflow accepts an autonomy selector at runtime.
- Changes to the shared execution sequence must update both entrypoints and
  pass a symmetry test.
- Existing callers pinned before this decision remain reproducible. Adopters
  receive the split entrypoint only when regenerated at this or a later
  immutable contract commit.

## Verification

The registered changelog-release suite generates both autonomy modes, proves
their workflow path and caller/callee permissions agree exactly, rejects a
runtime autonomy input, and mutation-tests cross-mode widening. Before merge,
two disposable workflow-dispatch callers pinned to the reviewed head establish
that GitHub admits both call graphs and creates their jobs.
