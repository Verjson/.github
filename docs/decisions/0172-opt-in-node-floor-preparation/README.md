# 0172 — Prepare an opt-in Node22 required-check lane

- **Date:** 2026-09-10
- **Status:** Accepted
- **Issue:** [#1274](https://github.com/Verjson/.github/issues/1274)
- **Scope:** Canonical preparation only; no live property, ruleset or consumer changes.

## Context

The Node core ruleset selects every repository with `verjson-stack=node` and
`verjson-core-checks=enforced`. Adding optional `ci-node22` checks there would
block repositories that never emit them. `verjson-object-storage#124` tracks an
existing repository floor rule and the corresponding reviewed merge-caller checks.
Moving its optional requirement to organization policy needs explicit opt-in,
retained authorization boundaries and actual consumer evidence.

## Decision

Define organization custom property `verjson-node-floor` as `single_select`, with
allowed values `disabled` and `node22`, required with default `disabled`, and
`values_editable_by: org_actors`. No repository needs to opt in merely because
it is a Node repository. This follows the existing organization-controlled property
convention; [GitHub's custom-property API](https://docs.github.com/en/rest/orgs/custom-properties)
defines the required/default-value and single-select fields.

Prepare `core-checks-node-floor` for the default branch, requiring all three
selectors: `verjson-stack=node`, `verjson-core-checks=enforced`, and
`verjson-node-floor=node22`. Its only additional checks are `ci-node22 / build-test`
and `ci-node22 / eligibility`, bound to the GitHub Actions App (`15368`). This is
one supported Node22 workflow lane, not a generic per-repository check language
or automatic derivation from an npm engine range.

`config/node-floor-baseline.json` records the reviewed projection of active Node
baseline rule `20515817`, read on 2026-09-10. The tool validates its identity,
selectors, rules and bypass actors before preserving the exact three bypasses:
OrganizationAdmin, release App `4583107`, and merge App `4693283`. Drift fails
preparation and requires review of the baseline and candidate together. GitHub
stores bypass lists separately per ruleset; this tool does not automatically
synchronize live rules or claim the lists can no longer diverge.

`scripts/node-floor-ruleset.py` has only `render` and `dry-run`. Rendering uses the
reviewed baseline or a validated saved snapshot. Dry-run performs two fixed GETs:
the baseline and organization property schema. A same-name property must match
the reviewed definition. Every output identifies itself as preparation only and
emits a **disabled** candidate; no command creates a property, opts in a repository,
updates a ruleset or retires the existing repository rule. The baseline digest
binds the full supplied/read observation, including any API metadata.

Consumer `required_checks` lists remain required, with exact workflow and App
identities. The privileged merge conformance check compares those reviewed lists
to effective branch requirements, and the merge App remains a bypass actor.
Moving a ruleset is not permission to omit floor checks from the autonomous lane.

## Verification and use

```bash
python3 scripts/node-floor-ruleset.py render > node-floor-proposal.json
python3 scripts/node-floor-ruleset.py render --baseline saved-node-baseline.json
python3 scripts/node-floor-ruleset.py dry-run > node-floor-observation.json
python3 scripts/node_floor_ruleset_test.py
```

The tests exercise disabled/default opt-out, conjunction of the three selectors,
exact contexts and bypasses, malformed inputs, type-sensitive drift rejection,
property conflicts, deterministic rendering and a fixed GET-only API boundary.
A successful dry-run does not inspect existing floor rules, opted-in repositories,
workflow implementations, package floors or PR runs; it cannot establish readiness.

## Live acceptance and retirement gates

Adoption is blocked by [#1303](https://github.com/Verjson/.github/issues/1303)
(exact App bindings for effective organization checks) and
[`verjson-object-storage#137`](https://github.com/Verjson/verjson-object-storage/issues/137)
(consumer check-list completeness and repository floor App binding). Resolve and
re-verify those prerequisites, then refresh the reviewed baseline snapshot before
rollout. These are identified adoption blockers, not a claimed live failure of this
prepared Node-floor policy.

A separately reviewed rollout must first snapshot the baseline and any existing
floor rule, verify property compatibility and absence of a conflicting organization
floor rule, and identify the exact intended repository cohort. Inspect each actual
main-branch `ci-node22` implementation and trusted workflow/App identities; require
fresh real-head successes for both checks and matching consumer `required_checks`.
Repositories without the workflow stay disabled.

After explicit live authorization, create the reviewed property and disabled rule,
set only verified repository opt-ins, and inspect effective targeting before a
separate active-enforcement transition. Preserve the existing repository rule until
fresh live evidence proves the organization floor rule blocks a failing floor check
and the intended successful path still merges under the reviewed policy. Verify a
non-opted-in Node repository remains unaffected. Coordinate duplicate-context rules
with strict conformance during cutover: do not claim simultaneous duplicate contexts
are admissible, and do not weaken checks or App binding merely to make it pass.

Retire the old repository floor rule only in that verified, reviewed cutover; retain
snapshots and an explicitly approved restore path. Record activation time, scope,
check/run identities and final ruleset state. Any unverified targeting, bypass drift
or conformance failure pauses rollout. This preparation does not close #1274 or
`verjson-object-storage#124` and does not authorize live enforcement.
