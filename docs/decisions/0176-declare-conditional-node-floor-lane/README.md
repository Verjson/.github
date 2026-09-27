# 0176 — Declare the conditional Node-floor lane in the canonical required-check contract

- **Date:** 2026-09-14
- **Status:** Accepted; live since 2026-09-27 (see the rollout amendment below)
- **Issue:** [#1274](https://github.com/Verjson/.github/issues/1274)
- **Amends:** [ADR 0172](../0172-opt-in-node-floor-preparation/README.md)
- **Category:** organization required checks and branch protection — **sensitive class**

## Context

`core-checks-node` (`20515817`) requires the same three contexts of every repository
carrying `verjson-stack=node` and `verjson-core-checks=enforced`. A Node version-floor
leg is not that shape: `Verjson/verjson-object-storage` ships `ci-node22` and needs it
required, while most Node repositories have no such workflow and would go permanently
red on a context that never reports. That repository therefore hand-built repository
ruleset `22590648` and mirrored the organization bypass actors by hand — working, and
deliberate drift that diverges the first time the organization baseline moves.

ADR 0172 prepared the opt-in lane and left rollout blocked on [#1303](https://github.com/Verjson/.github/issues/1303)
and [`verjson-object-storage#137`](https://github.com/Verjson/verjson-object-storage/issues/137).
Both are now closed. #1303's authorized rollout bound the four organization core
contexts to GitHub Actions App `15368` at 2026-09-10T15:24:14.976Z and
2026-09-10T15:24:16.455Z (ADR 0173's activation record), which invalidated ADR 0172's
reviewed baseline: the stored projection was the unbound preimage, so every `render`
and `dry-run` against live policy failed closed on drift. Preparation was blocked by
its own correctly-functioning guard.

Two further facts shaped this decision. `.github/required-check-contract.json` is the
declared registry of organization lanes — stack contracts, selecting properties, and
the planned ruleset set — and it had no entry for a lane only some repositories carry.
And `scripts/node-floor-ruleset.py` hard-coded producer App `15368` for the floor
contexts while its reviewed baseline recorded no producer at all, so the two could
disagree silently.

## Decision

**Refresh the reviewed baseline to the verified postimage.** `config/node-floor-baseline.json`
now records ruleset `20515817` as read on 2026-09-14; the delta against the reviewed
preimage is exactly the three `integration_id: 15368` additions, with identity,
selectors, enforcement, branch conditions and bypass actors unchanged. This is ADR
0172's required baseline refresh, not a relaxation of its drift guard.

**Derive the floor producer from that baseline instead of hard-coding it.** The
rendered candidate binds `ci-node22 / build-test` and `ci-node22 / eligibility` to the
single App the reviewed baseline binds all of its own required contexts to, and
preparation fails closed when the baseline carries no binding, a non-positive or
non-integer binding, differing bindings across contexts, or drifted context names.
Rendering the unbound preimage is now refused rather than silently emitting a
plausible `15368`. The derived value is published as `baselineProducerAppId`. If a
future organization repair moves core checks to a different producer, preparation
follows the reviewed baseline or stops; it cannot quietly propose a stale App.

**Make `baselineDigest` the identity of the reviewed baseline, not of the read.**
It now hashes the validated reviewed policy rather than the caller's observation, so
`render` and `dry-run` publish the same digest for the same underlying ruleset instead
of differing by whatever top-level metadata the live API happened to return. ADR 0172
described the field as binding the full observation; that reading made the digest a
property of the transport rather than of the policy under review, and two proposals
identical in `ruleset` and `baselineProducerAppId` were not comparable by it. Which
path produced a payload is already carried by `baselineSource`.

**Declare the conditional lane in the canonical contract.** `core-checks-node-floor`
joins `ruleset_plan.rulesets` with all three selectors — `verjson-stack=node`,
`verjson-core-checks=enforced`, `verjson-node-floor=node22` — and exactly the two
`ci-node22` contexts, and `property_schemas` gains `verjson-node-floor` with allowed
values `disabled` and `node22`. This is where a reader learns which organization lanes
exist and how each is selected; a lane that lived only inside one preparation script
was the coherence gap behind the consumer's hand-built ruleset.

**Keep the declaration and the prepared payload equal by test, not by derivation.**
`scripts/node_floor_ruleset_test.py` asserts the rendered candidate's contexts and
selectors equal the contract's declared entry, and that the floor contexts stay out of
`stacks.node.contexts`. We deliberately did not have the tool read its contexts from
the contract: the same file drives `scripts/required-checks-rollout.sh`, a mutation
path, and an ordinary contract edit must not be able to change a reviewed policy
payload without review. Equality-checked duplication with a failing test is the
smaller blast radius here; the cost is one declaration to keep in two places, which
the test makes impossible to forget.

## Preserved behavior

This change adds no validation to any repository. `ruleset_plan.rulesets` is consumed
by name for the single declared `rollout.ruleset_name` (`core-checks-node`), and
`property_schemas` has no code consumer, so the new entries are inert for the audit
and rollout paths; `scripts/required-checks-audit.test.sh` pins the widened set
deliberately. `stacks.node.contexts` is untouched, so no Node repository acquires a
floor requirement. The `verjson-node-floor` property defaults to `disabled`, and the
prepared candidate remains `enforcement: disabled`. A Node repository without a
`ci-node22` workflow keeps exactly the lane it has today, which is the point of making
the lane conditional rather than widening `core-checks-node`.

## What this does not do

No organization property is created, no repository is opted in, no ruleset is created
or updated, and `Verjson/verjson-object-storage`'s repository rule `22590648` is not
retired. `scripts/node-floor-ruleset.py` still has only `render` and `dry-run` and no
mutation mode. Consumer generated `required_checks` lists remain mandatory: moving the
requirement to organization policy is not permission to drop the floor entries from
the autonomous merge lane.

ADR 0172's live acceptance and retirement gates stand unchanged and unsatisfied. In
particular, rollout still requires explicit live authorization, fresh passing and
failing `ci-node22` PR-head controls with exact producer/workflow/head identity, an
unaffected non-opted-in control, coordinated duplicate-context cutover before the
repository rule is retired, and consumer-owned repair of that rule's own App bindings.
Neither this ADR nor its pull request closes #1274 or `verjson-object-storage#124`, and
neither grants live authority.

## Verification

```bash
python3 scripts/node_floor_ruleset_test.py
bash scripts/required-checks-audit.test.sh
bash scripts/required-checks-rollout.test.sh
python3 scripts/node-floor-ruleset.py render
```

The 2026-09-14 authenticated read of `orgs/Verjson/rulesets/20515817` that the refreshed
baseline records matched ADR 0173's activation postimage exactly, including its
`2026-09-10T15:24:16.455Z` update time. Rendering the pre-activation preimage now fails
closed, which is the regression this ADR's producer guard exists to catch.

## 2026-09-27 amendment: live rollout applied

**Status:** Accepted; the lane is live. Owner-authorized on 2026-09-26 (#1274).

**Failing control.** [verjson-object-storage#147](https://github.com/Verjson/verjson-object-storage/pull/147)
(head `5403f41`, never merged) added one vitest case that fails only on Node 22: every other
required context stayed `SUCCESS`, `ci-node22 / build-test` was `FAILURE` (run 36282960942),
and `mergeStateStatus` was `BLOCKED` — first under the repository ruleset, then again under
the organization lane alone before the PR was closed.

**Non-opted-in control.** `verjson-authn` (`verjson-stack=node`, `verjson-core-checks=enforced`,
`verjson-node-floor=disabled` by the schema default) shows zero `ci-node22` contexts in
`rules/branches/main`.

**Applied transaction**, with readback after each step:

1. Property schema `verjson-node-floor` created exactly as `scripts/node-floor-ruleset.py
   render` declares it (`single_select`, required, default `disabled`, allowed
   `disabled|node22`, `org_actors`).
2. Organization ruleset **24056850 `core-checks-node-floor`** created from the rendered
   candidate with `enforcement: active`: `~DEFAULT_BRANCH`, selected by
   `verjson-stack=node` **and** `verjson-core-checks=enforced` **and**
   `verjson-node-floor=node22`, requiring `ci-node22 / build-test` and
   `ci-node22 / eligibility` from integration 15368, bypass actors mirrored from
   `core-checks-node` (20515817). `config/org-ruleset-conformance-policy.json` carries its
   bypass contract so the scheduled audit reviews it.
3. `verjson-object-storage` set to `verjson-node-floor=node22`; `rules/branches/main` listed
   the floor contexts from both 24056850 and the hand-built repository ruleset 22590648.
4. Repository ruleset 22590648 deleted; readback shows the floor contexts sourced only from
   24056850, and #147 still `BLOCKED` with only `ci-node22 / build-test` red.

**Correction during rollout.** The first application on 2026-09-27 used an ad-hoc shape
(`enforced|exempt` values, no `verjson-stack=node` selector) instead of the declared one;
the independent review caught the divergence from this ADR and
`.github/required-check-contract.json`, and the live schema, value, and ruleset were rewritten
to the rendered candidate the same night before any repository other than object-storage
carried a value. The canonical contract needed no change.

Retired repository ruleset 22590648, for the record:

```json
{"name":"core-checks-node-floor","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
 "bypass_actors":[{"actor_type":"OrganizationAdmin","actor_id":null,"bypass_mode":"always"},
  {"actor_type":"Integration","actor_id":4583107,"bypass_mode":"always"},
  {"actor_type":"Integration","actor_id":4693283,"bypass_mode":"always"}],
 "rules":[{"type":"required_status_checks","parameters":{"do_not_enforce_on_create":true,
  "strict_required_status_checks_policy":false,
  "required_status_checks":[{"context":"ci-node22 / build-test","integration_id":15368},
   {"context":"ci-node22 / eligibility","integration_id":15368}]}}]}
```

This section satisfies the live-acceptance gates ADR 0172 enumerates (failing and
non-opted-in controls, exact producer/head identity, coordinated cutover).
Duplicate-context cutover was momentary (step 3 to step 4) and observed on one PR only;
`scripts/node-floor-ruleset.py` remains preparation-only and its `liveAcceptanceVerified`
flag is not a live probe.
