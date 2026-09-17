# 0190 — Pin the producer App of every required status check

- **Date:** 2026-09-17
- **Status:** Accepted
- **Issue:** [#1381](https://github.com/Verjson/.github/issues/1381)
- **Scope:** Sensitive class — organization ruleset / branch protection. This ADR adds
  the detection and records the reviewed mutation; **no live ruleset was mutated by this
  change.** (`config/required-check-bindings/README.md` says its two prepared payloads
  "have since been applied" — those are ADR 0173's, applied before this work; the
  `20515822` payload below is the one still held.)

## Context

ADR 0184's Gate A matches a required context by exact name **and** the App the ruleset
binds it to, so that a status published by some other App cannot satisfy a required
context by naming a job after it — the ADR 0024 class. That provenance half is
conditional on the ruleset actually binding the context.

Authenticated reads on 2026-09-17 establish what the live rulesets bind. Every required
status check on the organization is bound to App `15368` (`github-actions`, owner
`github`) except one:

| ruleset | id | required contexts → `integration_id` |
| --- | --- | --- |
| `changelog-contract-required` | `20513599` | `changelog / validate` → `15368` |
| `core-checks-node` | `20515817` | `ci / build-test`, `ci / eligibility`, `changelog-contract` → `15368` |
| `core-checks-actions` | `20515822` | `shell-tests` → **`null`** |

Issue #1381 described this as two unbound repository entries, on `Verjson/.github` and
`Verjson/verjson-git-runners`. That is the symptom, not the shape. `shell-tests` is not
required by any repository ruleset on either repository: it is required by the single
**organization** ruleset `core-checks-actions`, whose selector is
`verjson-stack=actions AND verjson-core-checks=enforced`. Those two repositories are
exactly the current cohort of that selector, which is why the defect surfaced as two
repositories. One organization-level entry is unbound, and one `PATCH` repairs every
repository the selector reaches, now and in future.

The root cause is a cohort omission: ADR 0173 prepared and applied exact App bindings for
`20513599` and `20515817`, and `core-checks-actions` was not in that cohort. Its
`config/required-check-bindings/*-after.json` payloads now match the live rulesets
byte-for-byte, so that rollout is consumed; its `README.md` still said none had been
applied, corrected in this change.

`assert-mergeable-head.sh` deliberately warns rather than refusing on an unbound context,
because refusing would reject currently-correct rulesets. That was the right call for the
merge gate — a warning makes the degradation visible, not permanent. It is not detection:
nothing failed on it, and the scheduled organization ruleset audit did not look at
bindings at all.

## Decision

`config/org-ruleset-conformance-policy.json` declares the producer App
(`required_check_producer_app_id: 15368`), and `scripts/org-ruleset-conformance.py` fails
when any organization ruleset requires a status context that is not bound to exactly that
App. Requiring merely *some* binding would still admit a wrong-but-present App, so the
policy pins the expected identity the same way it already pins
`release_authorization_bypass.actor_id`.

The finding is attributable per ruleset and context and prints **alongside** a
release-authorization finding rather than instead of it. That matters concretely: the
scheduled audit has been failing daily since at least 2026-09-13 on
`cli-projects-package-surface-required-workflow` (`21830367`), so an early return would
have hidden this finding behind an unrelated one.

A malformed `required_status_checks` parameters block, or an `integration_id` that is
neither `null` nor a positive integer, exits `2` rather than raising. Consistent with
ADR 0024, nothing here is relaxed: an absent or unrecognized binding fails closed.

## The mutation this ADR authorizes, held for human application

Live preimage, `GET orgs/Verjson/rulesets/20515822` (2026-09-17, `updated_at`
`2026-08-23T19:54:53.361Z`):

```json
{"type": "required_status_checks",
 "parameters": {"strict_required_status_checks_policy": false,
                "do_not_enforce_on_create": true,
                "required_status_checks": [{"context": "shell-tests"}]}}
```

Apply, changing that one field and nothing else:

```bash
gh api --method PUT orgs/Verjson/rulesets/20515822 --input - <<'JSON'
{"rules": [{"type": "required_status_checks",
            "parameters": {"strict_required_status_checks_policy": false,
                           "do_not_enforce_on_create": true,
                           "required_status_checks": [{"context": "shell-tests",
                                                       "integration_id": 15368}]}}]}
JSON
```

Roll back by replacing that `required_status_checks` array with the preimage above.

Producer evidence for this cohort, read authenticated on 2026-09-17: on the default-branch
head of each selected repository the `shell-tests` check run reports App `15368`, slug
`github-actions`, owner `github` — `Verjson/.github` at
`17fdf6a1adc7e1340f903d2e238d4515baaafd7b` and `Verjson/verjson-git-runners` at
`a50e519d0f11f6988aaadbc45358bc6c75d39563`. Binding a context to an App that does not
publish it makes the context unsatisfiable and blocks every merge in the selected
repositories, including the merge that would undo it, which is why this is applied by a
human against a re-read preimage rather than by CI.

Until it is applied the scheduled audit reports this finding daily. That is the intended
state: the gap is real, and ADR 0024 forbids silencing it.

## Consequences

- An unbound or wrongly-bound required context is detected organization-wide, not only on
  the two repositories where it was noticed.
- The nightly audit stays red until the `20515822` binding is applied, and separately
  until `21830367` is adjudicated. That second finding is pre-existing and out of scope
  here; `is_exact_bypassless_required_workflow` requires `enforcement == "active"` while
  that ruleset is `disabled`, and it is tracked separately.
- Adding a required context to an organization ruleset now requires declaring its
  producer App, or the audit fails.
- **This audit pins the producer of the contexts that exist; it does not assert which
  contexts must exist.** A ruleset whose `required_status_checks` rule is deleted
  outright, or whose check array is empty, is silent here and exits 0 — `shell-tests`
  could stop being required across the cohort without this check noticing. Presence of
  the required contexts is a separate invariant, owned by the required-workflow
  assertions this audit already carries for the bypassless rulesets. Naming the boundary
  rather than letting "an absent or unrecognized binding fails closed" be read as
  covering an absent *rule*.
- **The declared producer is a single scalar with no exception list**, unlike the sibling
  `bypassless_required_workflows`. A required context legitimately published by some
  other App — a third-party check, or a second GitHub App — makes this audit
  unsatisfiable until the policy schema grows a per-context override. That is deliberate
  for now: every context the organization requires today is published by
  `github-actions`, and a list of allowed producers is the shape in which an unwanted
  producer gets quietly added.

Related: ADR 0024, ADR 0173, ADR 0184, ADR 0186.
