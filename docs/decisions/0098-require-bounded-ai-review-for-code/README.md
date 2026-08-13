# 0098 — Require bounded AI review for code changes

- **Date:** 2026-08-12
- **Status:** Accepted
- **Issue:** [Verjson/.github#767](https://github.com/Verjson/.github/issues/767)
- **Amends:** [ADR 0090](../0090-human-first-opt-in-ai-review/README.md), [ADR 0080](../0080-one-automatic-paid-ai-review-per-head/README.md)
- **Category:** AI merge gate / cost authorization (sensitive-class)

## Context

ADR 0090 made model execution opt-in so provider or workflow outages could not remove
the protected human merge path. That classifier also let ordinary code, executable
workflow changes, dependency-action digest updates, and deletions reach
`REVIEW_OUTCOME=skipped`. PRs #747, #763, and #764 demonstrated the gap: each changed
executable behavior without receiving any AI code-review pass.

The review payload deliberately removes generated lockfile hunks. Paying a model to
review a lockfile-only patch therefore adds no evidence beyond deterministic integrity,
audit, and CI. Non-agent documentation similarly does not benefit enough to justify a
mandatory provider call. Agent instructions, skills, rules, and prompts are executable
inputs to autonomous systems and are not ordinary documentation.

A per-run retry bound is insufficient. An explicit `re-review`, a provider fallback,
or a workflow rerun can otherwise exceed the intended PR-wide cost ceiling. Failed and
inconclusive provider calls must count, including a call interrupted before it can post
a verdict.

## Decision

The trusted classifier requires the AI lane for code, scripts, executable workflows and
actions, runtime configuration, dependency manifests and pins, prompts, policies, and
agent-instruction Markdown. A deletion is classified by the deleted path; deleting code
or agent instructions is not a fast lane. Only generated-lockfile-only changes and
non-agent documentation/community-health changes use the no-model lane.

Every provider invocation reserves a PR-visible pass slot before the call as an
exact-head `COMMENT` review authored by the dedicated authorization App. Its token is
minted with only pull-request write permission. The trusted workflow counts only the
App's exact marker on a review whose commit matches the marker, then independently
verifies the referenced exact-head authorization check belongs to that App and binds
the same repository, PR, and head. Shared `github-actions[bot]` comments cannot forge
this evidence. A narrowly pinned rollout check/run tuple counts the already-consumed,
cancelled first attempt on PR #769 after all of those historical facts are revalidated.

A pass remains consumed when input preparation, the provider, semantic validation, or
verdict publication is inconclusive or fails. A DeepSeek fallback is a separate pass.
Fallback admission derives directly from pass 1's output rather than rereading the
just-written review through an eventually consistent API. The cumulative ceiling is
two passes for the entire PR, including explicit re-review. The workflow refuses a
third call.

One usable verdict is required before the dedicated App can approve or autonomously
merge. A later base update with the same stable patch-id reuses the trusted usable
verdict without reserving another slot. Missing, forged, stale-patch, inconclusive, or
over-cap evidence cannot mint App authority.

ADR 0090's protected human fallback remains: provider availability is not a branch
protection primitive, advisory findings never submit `CHANGES_REQUESTED`, and a human
may still authorize a merge under the repository's ordinary approval policy. The
mandatory classification and two-pass invariant constrain model execution and AI
approval/merge authority; they do not turn an external provider outage into an
organization-wide merge veto.

## Consequences

- Ordinary code and executable dependency updates receive AI review automatically;
  the `ai-review` label is no longer required for initial classification.
- Operators see pass `1/2` or `2/2` on the PR before provider execution.
- An unusable second pass leaves autonomous approval and promotion fail-closed without
  spending on a third model.
- Generated lockfile-only and non-agent documentation changes retain deterministic,
  no-model validation.
- The human approval fallback and all exact-head receipt, hold, App-identity, and
  privileged-promotion checks remain unchanged.

## Verification

`classify-review-policy.test.py` covers each required and exempt surface, including
deletions. `review-attempt-count.test.py` covers App-authored, shared-Actions forged,
foreign-PR/head, duplicate, failed, and malformed evidence. The registered merge-gate
suite mutation-tests the two-pass admission boundary, least-privilege token mint,
read-after-write avoidance, unchanged-patch reuse, and fail-closed authorization.
