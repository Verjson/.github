# 0061 — The changelog check is a required status check, scoped by a repository property

- **Date:** 2026-08-06
- **Issues:** [Verjson/verjson-email#31](https://github.com/Verjson/verjson-email/issues/31)
- **Extends:** ADR 0038 (canonical changelog contract)
- **Category:** organization ruleset / branch protection — **sensitive class**

## Context

Every adopter of the ADR 0038 contract runs `changelog-validate.yml` on `pull_request`
through a generated `.github/workflows/changelog.yml` caller. Nothing required it. The org
ruleset `main-protection` (id 18098028) carries `deletion`, `non_fast_forward`,
`pull_request`, `required_linear_history` and `workflows`, and no `required_status_checks`
rule at all, so the contract was advisory everywhere.

verjson-email#31 observed the consequence: #29 and #30 merged into `main` with no changelog
run recorded. Both branched before the caller landed and were never rebased, so the check
never fired, and nothing noticed that a check which should have existed did not.

The merge gate cannot close this. It verifies the checks a PR *has*; it has no way to know
which checks a PR *should* have had. That knowledge only exists in a ruleset.

### What requiring the check does and does not do

verjson-email#31 proposed the rule as a defence against a PR landing with an empty `NEXT/`.
It is not one, and the distinction decides how much this ADR can claim.

`changelog.py check-pr` forbids exactly two things: editing `CHANGELOG.md` or
`CHANGELOG/**`, and consuming (deleting or renaming out of) a `NEXT/` fragment. `validate`
checks that the fragments present are well-formed. **Neither requires a fragment to exist.**
Verified on a scratch repository: a commit that changes `package.json` and adds no fragment
returns rc 0 from both `validate` and `check-pr`. Requiring the check would not have blocked
verjson-email#29 or #30 on the missing-fragment ground the issue gives.

So this decision buys a narrower, real thing: **no PR merges without the contract having
been evaluated at all.** Well-formedness is enforced, released snapshots and generated
aggregates are protected from ordinary PRs, and a branch too stale to have run the check
cannot merge. Whether a fragment should be *mandatory* is a separate decision about
`check-pr`, deliberately not taken here — and it is where the Renovate question the issue
raises actually lives. Today no PR is required to carry a fragment, so this rule has no
effect on dependency-bump PRs at all.

## Decision

**A new organization ruleset `changelog-contract-required` (id 20513599) requires the
`changelog / validate` context on the default branch, scoped by a custom repository
property rather than a repository list.**

- **Scope is a property, not a list.** The org custom property `changelog-contract`
  (`single_select`, `adopted` / `none`) marks repositories that carry the generated caller.
  The ruleset condition is `repository_property: changelog-contract == adopted`. A list of
  23 repository names would be stale the first time a repository adopts; a property is set
  by whoever adopts and the ruleset follows. Confirmed applied on an adopter and absent on a
  non-adopter through `GET /repos/{repo}/rules/branches/main`.
- **67 of 91 active repositories have not adopted the contract and are untouched.** The
  requirement reaches only the 23 that have.
- **`strict_required_status_checks_policy: false`.** Requiring a branch to be up to date
  with `main` before merging would serialize every merge in the organization behind a
  rebase. The staleness this rule exists to catch is "the check never ran", which the
  requirement catches on its own.
- **`do_not_enforce_on_create: true`**, so creating the default branch is not gated on a
  check that cannot have run.
- **Bypass is `OrganizationAdmin` only.** The merge gate's app is deliberately *not* a
  bypass actor. Granting it one would make the rule advisory again on the exact path the
  organization merges through — the gate merged verjson-email#29 and #30. `--admin` remains
  available to a human for a genuine emergency, which is what the org-admin bypass is.

### Evaluate mode was tried and does not work on this plan

The intended sequencing was to ship the rule in `enforcement: evaluate` first, so it would
report what it would have blocked before blocking anyone. The API **accepts** `evaluate` on
this organization's Team plan — a probe ruleset scoped to a non-existent repository was
created and deleted to confirm it — but the results are unreadable:
`GET /orgs/Verjson/rulesets/rule-suites` returns `403 Upgrade to GitHub Enterprise to enable
this feature`. An evaluate-mode rule here blocks nothing and reports nothing.

Leaving it in evaluate would have been worse than either alternative: a rule that appears to
be staged, provides no protection, and produces no data. The blast radius was measured
directly instead, by sweeping every open non-draft PR on the 24 tagged repositories for the
`changelog / validate` check run:

| Result | Count | Disposition |
| --- | --- | --- |
| Check present and green | 22 | unaffected |
| Check absent (branch predates adoption) | 4 (verjson-cloud-storage #18, #25, #26, #43) | #43 rebased, check now runs; #18/#25/#26 already unmergeable on conflicts, so the rule costs them nothing |
| Non-conforming caller | 1 (`Verjson/agents` #9) | excluded from scope, see below |

`Verjson/agents` is the one genuine casualty and is **excluded** by setting its property to
`none`. Its caller is hand-edited away from the generated shape: the `changelog` job carries
an `if:` exempting the `automation/canonical-publication` branch, and a second job
`publication-changelog` reports as `validate` instead. It also pins contract `1486d44d`
rather than the fleet's `f12dca77`. Requiring a context that repository may legitimately skip
would wedge its publication flow, and choosing between "break the flow" and "weaken the rule"
is its own decision, not a footnote to this one. Tracked separately.

## Consequences

- A PR on an adopter whose branch predates the caller now cannot merge until it is rebased.
  That is the intended cost and the only behavioural change for the 23 in scope.
- Adopting the contract now has a second step: set `changelog-contract=adopted` on the
  repository. `scripts/gen-changelog-caller.sh` does not do this, because it writes files and
  cannot mutate organization state. Until it prints the reminder, the adopting PM sets it.
- The rule pins one context string, `changelog / validate`. It is the caller job name
  (`changelog`, uniform across all 24 surveyed repositories) plus the reusable workflow's job
  name (`validate`). Renaming either in `gen-changelog-caller.sh` or in
  `changelog-validate.yml` silently turns the requirement into a permanent block on every
  adopter, because the required context would never report. Either rename must update this
  ruleset in the same change.
- `Verjson/agents` remains unprotected by this rule while its caller stays non-conforming.

## Rollback

`PATCH /orgs/Verjson/rulesets/20513599 -f enforcement=disabled` turns the rule off without
losing its definition; `DELETE` removes it. Neither touches repository state, and the custom
property is inert on its own. Rolling back restores exactly the advisory behaviour
verjson-email#31 reported.
