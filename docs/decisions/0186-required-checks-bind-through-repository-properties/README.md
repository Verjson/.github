# 0186 — Required status checks bind through repository properties, not per-repository rulesets

- **Date:** 2026-09-17
- **Status:** Accepted
- **Related:** [ADR 0178](../0178-publish-deferred-ci-as-its-own-check/README.md), [ADR 0184](../0184-merge-gates-assert-execution-not-absence-of-red/README.md), [ADR 0185](../0185-org-contract-distribution/README.md)
- **Issues:** [Verjson/verjson-ci#186](https://github.com/Verjson/verjson-ci/issues/186), [Verjson/verjson-compliance#23](https://github.com/Verjson/verjson-compliance/issues/23), [Verjson/verjson-compliance-schema#12](https://github.com/Verjson/verjson-compliance-schema/issues/12)
- **Superseded in part by:** [ADR 0206](../0206-ai-authorization-property-is-independent/README.md)

## Context

Three repositories were reported as protecting `main` with a ruleset that
declares no required status checks, so a green check rollup gated nothing and a
merge predicate reading that rollup certified nothing.

The reported framing — three repositories each carrying their own defective
ruleset — is **factually wrong**, and the correction is the substance of this
decision. Established by direct API inspection on 2026-09-17:

- `gh api repos/Verjson/<repo>/rulesets` returns exactly one ruleset for each of
  the three repositories, and it is the **same** ruleset in all three:
  id `18098028`, name `main-protection`, `source_type: Organization`,
  `source: Verjson`.
- None of the three repositories has any repository-level ruleset at all.
- `main-protection` carries `deletion`, `non_fast_forward`,
  `required_linear_history`, and `pull_request` rules. It carries no
  `required_status_checks` rule, and it applies to `~DEFAULT_BRANCH` across the
  organization — roughly 95 repositories, not three.

So the missing checks were never a property of these three repositories'
protection. `main-protection` deliberately carries only the universal,
content-independent rules. Required contexts are necessarily repository-specific,
and they live elsewhere.

### How required contexts actually bind

The organization already carries them in separate rulesets selected by **custom
repository properties**, not by repository name or id:

- `core-checks-node` (`20515817`) — selects `verjson-stack=node` **and**
  `verjson-core-checks=enforced`; requires `ci / build-test`,
  `ci / eligibility`, `changelog-contract`.
- `core-checks-actions` (`20515822`) — selects `verjson-stack=actions` and
  `verjson-core-checks=enforced`; requires `shell-tests`.
- `changelog-contract-required` (`20513599`) — selects
  `changelog-contract=adopted`; requires `changelog / validate`.
- `ai-authorization-arm-required` (`20722935`) — selects
  `verjson-core-checks=enforced`; requires the `gate-rearm.yml` workflow.

`gh api repos/Verjson/<repo>/properties/values` returned an **empty set** for all
three repositories. Correctly configured adopters — `verjson-ai`,
`verjson-authn` — carry all three properties. The repositories were therefore
unenrolled, not misprotected.

## Root cause

Enrollment in the organization's required-check contract is expressed as
repository property values, and nothing sets those properties when a repository
is created or adopts the contract. A repository with no properties silently
matches no required-check ruleset while still appearing protected, because
`main-protection` does apply and does gate merges on review, linear history, and
squash. The protection that is present masks the verification that is absent.

## Decision

**Enroll the three repositories by setting their custom repository property
values. Do not author repository-level rulesets, and do not add required status
checks to `main-protection`.**

Applied values, matching the `verjson-ai` / `verjson-authn` reference exactly:

- `verjson-ci`: `verjson-stack=node`, `verjson-core-checks=enforced`,
  `changelog-contract=adopted`
- `verjson-compliance`: same
- `verjson-compliance-schema`: same

Two alternatives are explicitly rejected:

- **Adding required contexts to `main-protection`.** It is one organization-wide
  ruleset over ~95 repositories with heterogeneous stacks. Any context added
  there would be required of every repository, and a required context that a
  repository does not emit blocks every pull request in it permanently. This
  would convert a gap in verification into a fleet-wide outage.
- **Authoring a repository-level ruleset per repository.** It would work, but it
  forks the fleet into two enrollment mechanisms, and per-repository rulesets do
  not inherit later contract changes. The property mechanism already exists, is
  already the organization's convention, and propagates centrally.

### A required context must be one the repository actually emits

This is the constraint that made the change non-trivial, and it is recorded here
because it is easy to get wrong in the other direction.

For a **reusable-workflow call, the published check context is prefixed by the
caller job id, not by the workflow name.** `core-checks-node` requires
`ci / build-test` and `ci / eligibility`, which encodes a convention that the
caller job must be named `ci`.

Observed contexts on recent pull requests, before any change:

- `verjson-compliance`, `verjson-compliance-schema` — publish `ci / build-test`,
  `ci / eligibility`, `ci / deferred-ci`, `ci / acquire-secretless-dependencies`,
  `changelog-contract`, `changelog / validate`. Already conformant; enrollment
  alone is sufficient and safe.
- `verjson-ci` — published `build-test / build-test` and
  `build-test / eligibility`, because its caller job was named `build-test`.
  Enrolling it unchanged would have required two contexts nothing in the
  repository emits, wedging every pull request permanently.

`verjson-ci` therefore renames its caller job to `ci`
(`Verjson/verjson-ci#187`) **before** enrollment, and enrollment follows only
once `ci / *` contexts are observed on a real pull request.

`deferred-ci` is deliberately **not** added to any required context set, per
ADR 0178 and the permanently-unsatisfied-context wedge of
[#191](https://github.com/Verjson/.github/issues/191).

### Binding a context to an app is a separate, untouched defect

`core-checks-node` and `changelog-contract-required` bind their contexts to
`integration_id: 15368`. `core-checks-actions` binds `shell-tests` with no
`integration_id`, so any actor able to post a commit status can satisfy it.

That defect is tracked as [#1381](https://github.com/Verjson/.github/issues/1381)
and is **out of scope here**. This decision neither fixes nor worsens it: the
three repositories are enrolled as `verjson-stack=node`, so every context newly
required of them is app-bound.

## Consequences

- Each of the three repositories now requires `ci / build-test`,
  `ci / eligibility`, `changelog-contract`, and `changelog / validate` on
  `main`. A green rollup now certifies that verification ran.
- Setting `verjson-core-checks=enforced` also enrolls them in
  `ai-authorization-arm-required`, injecting the organization's `gate-rearm.yml`
  required workflow. `verjson-authn` is the precedent that this is safe without a
  repository-local `ai-review-app` environment: its `arm` job concludes SUCCESS
  and its advisory `AI review authorization` context concludes FAILURE without
  blocking merges, because `arm` is `continue-on-error`.
- `verjson-ci`'s published check names change from `build-test / *` to `ci / *`.
  Anything pinned to the old names must be updated; a fleet grep found only a
  dated changelog fragment, which is a historical record and is left alone.
- Enrollment remains manual. Nothing yet asserts that a repository carrying the
  changelog contract also carries the properties. That gap is real and is the
  natural successor to this decision under ADR 0185's versioned-contract model;
  it is not closed here.

## Verification

- Before: `gh api repos/Verjson/<repo>/rulesets` -> only `18098028`
  `main-protection`, no `required_status_checks` rule;
  `gh api repos/Verjson/<repo>/properties/values` -> `[]`.
- After: `properties/values` returns the three enrolled values, and
  `gh api repos/Verjson/<repo>/rulesets` additionally returns
  `core-checks-node`, `changelog-contract-required`, and
  `ai-authorization-arm-required`.
- Each required context was confirmed present in a real pull request's
  `statusCheckRollup` before being made required.
