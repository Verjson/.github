# 0094 — Require the authorization arm from its own property-scoped ruleset

- **Date:** 2026-08-11
- **Status:** Accepted
- **Issue:** [#748](https://github.com/Verjson/.github/issues/748) (outage: [#728](https://github.com/Verjson/.github/issues/728))
- **Supersedes:** [ADR 0091](../0091-ruleset-requires-authorization-arm/README.md)
- **Amends:** [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md), [ADR 0090](../0090-human-first-opt-in-ai-review/README.md)

## Context

ADR 0091 decided to retarget the one workflow selected by `main-protection`
(`18098028`) from `ai-review-merge.yml` to `gate-rearm.yml` "in a single ruleset
update". That decision has not been executable, and the organization gate has
been down since 2026-08-08 while it waited.

Two facts, both established against live state on 2026-08-11:

**The precondition cannot be met in any near term.** ADR 0091 requires canonical
deterministic required CI on every governed default branch before retargeting,
because `main-protection` applies to `~ALL` and the arm is deliberately
non-vetoing — arming a repository with no deterministic CI would leave human
review as its only automated precondition. `ai-review-required-workflow-audit.py`
reports **70 of 91** organization repositories missing it. That is not a property
backfill: setting `verjson-core-checks=enforced` on a repository that produces no
`ci / build-test`, `ci / eligibility`, or `shell-tests` context blocks its pull
requests permanently. The precondition is a multi-repository CI rollout program,
and the gate stays dark for its duration.

**The scope of the workflows rule and the scope of branch protection were never
the same requirement.** `main-protection` carries five rules: `deletion`,
`non_fast_forward`, `required_linear_history`, `pull_request`, and `workflows`.
The first four must apply to `~ALL` — every repository needs force-push and
deletion protection regardless of its CI maturity. Only `workflows` needs to be
limited to repositories that can safely be armed. Because both live in one
ruleset, ADR 0091 had to choose one scope for both, and correctly chose the
stricter precondition rather than weakening branch protection.

The organization already models exactly this pattern three times.
`core-checks-node`, `core-checks-actions`, and `changelog-contract-required` are
separate rulesets whose `conditions` select repositories by **custom repository
property** rather than by name. `verjson-core-checks: enforced` is the property
that already gates deterministic CI, and all 21 repositories carrying it also
carry a declared `verjson-stack`. A workflows rule scoped to that same property
is armed exactly where deterministic CI exists, by construction, with no
coverage gap to close first.

## Decision

Split the `workflows` rule out of `main-protection` into its own organization
ruleset, `ai-authorization-arm-required`, and select `gate-rearm.yml@main` there.

- `main-protection` keeps `deletion`, `non_fast_forward`,
  `required_linear_history`, and `pull_request`, unchanged, at `~ALL`, with its
  bypass actors and ref conditions untouched. It loses one rule and nothing else.
- `ai-authorization-arm-required` carries the **relocated** rule — same
  parameters, same `do_not_enforce_on_create`, same source repository and
  immutable ref, differing only in the selected path — with the same bypass
  actors and the same ref conditions as the ruleset it left.
- Its `conditions` select by `repository_property` `verjson-core-checks:
  enforced` and **never** by `repository_name`. Scoping it by name would
  reconstruct the `~ALL` hazard the split exists to remove and silently decouple
  the arm from deterministic CI.

Two consequences of the narrower scope are deliberate, and are the substance of
what this ADR changes:

1. **Deterministic-CI coverage is required of armed repositories only.** A
   repository without the property gets no arm, so the arm cannot become its only
   merge precondition. The hazard ADR 0091 guarded against does not arise there.
   A repository that carries the property but no declared stack is still
   rejected — that one *is* armed with nothing deterministic behind it.
2. **The App credential must reach armed repositories only.** ADR 0091 treated
   organization-wide reach as a rollout blocker; requiring fleet-wide reach for a
   rule that governs a subset was demanding a scope expansion the decision did
   not need. Least privilege here means `selected` over the armed set — which
   also narrows `AI_REVIEW_APP_PRIVATE_KEY` from its current `visibility: all`
   (see [#265](https://github.com/Verjson/.github/issues/265)).

The audit's states become `ready` (protection ruleset is the full reviewed
preimage; the arm ruleset does not yet exist) and `split` (protection ruleset is
the postimage; exactly one ruleset matches the full reviewed arm image). The
postimage is **derived** from the preimage by removing the workflows rule and
compared, so a contract that also relaxes enforcement, widens a bypass, drops a
protection rule, or narrows `repository_name` while presenting itself as "just
moving the workflows rule" is rejected rather than reviewed by eye. Rollback
restores the verified preimage and deletes the arm ruleset.

### One deliberate exception, and its bound

`--render-split-payload` and `--render-arm-ruleset-payload` run the full audit
with `allow_unschedulable_selection=True`. Every other precondition still
applies. This exists because the currently selected workflow being unschedulable
*is the outage the split repairs* (#745): refusing to render the remedy while the
defect is present would make the audit hold the outage in place. The exception is
bounded three ways — it never applies to a plain audit, so the finding is never
suppressed; it never applies in `split` state, where a dead selection is a fresh
regression rather than a state being repaired; and it suppresses only that one
condition.

## Consequences

- The gate is restored for the 21 repositories that have canonical deterministic
  CI, without waiting on the other 70 and without weakening branch protection
  anywhere.
- **Arming a repository becomes a property assignment.** Setting
  `verjson-core-checks=enforced` now also grants the arm. That is the intended
  coupling — the property means "this repository has deterministic CI" — but it
  makes the property load-bearing for two things at once, and any future tool
  that sets it must be reviewed on that basis.
- The 70 uncovered repositories keep human review and ordinary branch protection
  and are no longer a blocker for anything. Closing that gap remains worthwhile
  and is now ordinary backlog rather than a release gate.
- Two organization rulesets must be reasoned about together. The audit's
  exclusivity check enforces that exactly one ruleset ever selects the retired or
  replacement path, so "both are required" and "neither is" both fail loudly.
- Rollback is two mutations rather than one: restore the preimage and delete the
  arm ruleset. The audit refuses to render the rollback unless it first proves
  the live state is the full split image.
