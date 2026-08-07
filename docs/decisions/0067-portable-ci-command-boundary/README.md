# 0067 — Portable CI commands stop at the GitHub control plane

- **Date:** 2026-08-07
- **Issues:** [#483](https://github.com/Verjson/.github/issues/483), [#537](https://github.com/Verjson/.github/issues/537)
- **Category:** CI portability
- **Status:** Accepted

## Context

The outage investigated in #483 prevented jobs from acquiring runners. Moving
the same commands into another build engine would not have created execution
capacity: portability and availability are different failure domains.

Some repository work is ordinary process execution: linting workflows, running
behavioral tests, rendering changelog fragments, and checking the generated ADR
index. Other work is GitHub's control plane: reading pull-request and check
metadata, producing GitHub check contexts, enforcing organization rulesets, and
performing a privileged merge.

Treating both classes as one portability problem either overstates what a local
engine can recover or pulls privileged GitHub behavior into an abstraction that
cannot provide its semantics.

## Decision

We separate two capabilities:

1. **Engine portability** means a command has a provider-neutral local entry
   point and can run on any compatible execution substrate.
2. **Execution availability** means an admitted substrate can accept the work
   now. Runner overflow, admission, and security boundaries govern this
   capability independently.

The repository exposes `lint`, `test`, `render`, and `adr-index` through a
standard-library Makefile. Existing workflow steps consume the Make targets
where the mapping is direct. Tests execute each target through probes so the
target names cannot silently drift from their underlying commands.

`ai-review-merge.yml` and `ai-privileged-merge.yml` are explicitly outside this
portability boundary. GitHub remains the non-portable floor for their metadata,
check-context, ruleset, and privileged-merge behavior. Portable build workflows
may later map provider context into neutral environment variables under #538,
but the merge control plane must not adopt that abstraction.

Public hosted-to-self-hosted overflow is separate sensitive topology work under
#536. It requires its own ADR, fork-code exposure analysis, behavioral routing
tests, rollout evidence, and mandatory human review. This decision changes no
runner labels, groups, lanes, or admission rules.

We reject Earthly and Dagger for now. This shell/Python repository does not have
enough build-graph complexity to justify adding and securing another build
engine. `act` remains an evaluation under #539 after command extraction, not a
presumed replacement for GitHub control-plane behavior.

## Consequences

- Developers and CI have stable local entry points for the portable command
  subset without a new runtime dependency.
- A green local target proves command portability, not runner availability or
  equivalence with the GitHub merge gate.
- The `test` target is the documented behavioral smoke test, not an assertion
  that it reproduces every setup-dependent step in `actions-ci`.
- Expanding the portable subset requires an executable target contract; changing
  runner topology requires the separate #536 security and human-review path.
