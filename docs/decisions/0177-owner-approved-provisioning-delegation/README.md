# 0177 — Owner-approved delegation for agent-operated provisioning

- **Date:** 2026-09-14
- **Issue:** [#1325](https://github.com/Verjson/.github/issues/1325)
- **Category:** authorization delegation and credential custody

## Context

The canonical operational contract describes provisioning as a sequence of "operator
steps", which reads as a requirement that a human type every command. That is neither
what the steps are for nor how the
[verjson-ci provisioning contract](https://github.com/Verjson/verjson-ci/tree/main/packages/provisioning)
models them: its `apply`, `rotate` and `retire` operations suspend on a typed
external-action continuation owned by the organization owner or the credential
custodian. What the contract lacked was a way to say, once, that a named executor may
carry out a specific reviewed plan.

Without that, every route is bad. Either a human replays commands an agent already
planned, or the agent proceeds on its own assertion that it was approved — the failure
mode [ADR 0166](../0166-environment-only-app-private-keys/README.md) and
[ADR 0169](../0169-sealed-environment-app-bootstrap/README.md) exist to prevent.
The custody record also stopped at the three environment-bound roles, leaving the other
four owned roles with no written storage, rotation or proof contract.

## Decision

An owner delegates provisioning by issuing a **grant**: a document naming the issuer,
the executor, an immutable `Verjson/verjson-ci` contract SHA, an exact target cohort,
the permitted effects per role, per-effect owner consent, plan and review evidence, a
bounded expiry, and a revocation surface. One reviewed grant authorizes every action it
lists, with no per-call reconfirmation inside that scope.

`scripts/provisioning-delegation-validate.py` is the single offline decision procedure
over `config/provisioning-delegation-contract.json` and
`config/app-role-custody-inventory.json`. It reads documents, never credentials or the
network, and emits an authorization receipt.

Authority is structural, so it cannot be asserted:

- Only an organization owner issues a grant, and the issuer may not be the executor.
  Model output, unattended mode, an executor-authored approval field, and any
  unrecognized field are rejected.
- Every effect the contract lists as owner-gated — installation and permission changes,
  secret write and withdrawal, supersession enablement, runner registration, governance
  changes, commercial terms, resource destruction — needs its own consent record with a
  GitHub-hosted reference and named approvers who exclude the executor.
- A target may request only its role's permitted effects and must declare exactly the
  catalog permission ceiling. That is the mechanical form of review/merge/release
  separation, read-only ruleset audit, isolated runner control, and the dependency
  supersession enablement gate.
- The cohort must be exact. An incomplete inventory is unknown, never proof of scope,
  so `cohort.requiredRoles` names the roles the inventory must cover and a missing
  role is an input error rather than a smaller cohort.
- The pin must be one 40-hex commit; a branch or tag is rejected.

The custody inventory is extended from three role environments to all seven owned
roles, each with storage, trust, rotation and role-specific positive, negative and
explicitly *insufficient* proof.

The inventory separates the custody an owner decided from the custody actually in
place. `custodyDecision` is the decision; `migrationStatus.achievedCustody` is the
state reached, and `migrationStatus.survivingBroadCopies` names each organization
secret copy of a role key that still exists, with the visibility
`config/org-actions-secret-policy.json` declares for it. `merge` and `ai-review` are
decided environment-only and have not achieved it: broad copies remain for unprepared
consumers, as ADR 0166 records, and their withdrawal is tracked by
[#1285](https://github.com/Verjson/.github/issues/1285). Recording only the decision
would have read as a completed withdrawal, which is the more dangerous direction for a
credential-custody record to be wrong in — a reader would conclude the broad exposure
was gone. The validator therefore refuses an inventory in which a role claims its
decided custody as achieved while its own record says copies are pending, so the
optimistic reading cannot be written down at all.

Merging this record activates nothing. The contract ships as
`activation.status: defined-not-activated` and the validator withholds authorization
with reason `contract-not-activated` until an owner changes that status in a reviewed
pull request. Whole-cohort staging, the protective shared-pin freeze, native admission
and the broad-copy withdrawal conditions in
[#1285](https://github.com/Verjson/.github/issues/1285) are unchanged; this record is
not permission to advance one repository alone or to bypass a required check.

## Consequences

An owner can authorize an agent-run provisioning plan once, and the resulting authority
is auditable, bounded, revocable and machine-checkable rather than conversational. The
cost is a second document class to keep current: a role added to the verjson-ci catalog
must be added to the custody inventory, and the validator fails closed on an unknown
`role_id` until it is. Another organization supplies its own contract and inventory
through `--contract` and `--inventory`; no policy in this repository binds it.

Historical records stand. This decision supersedes nothing: ADR 0166 keeps custody of
the three environment-bound keys, and ADR 0169 stays retired rather than revived.
