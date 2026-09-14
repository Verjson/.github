# Owner-approved provisioning delegation

An "operator step" in the canonical provisioning contract identifies the accountable
authority for an action. It does not require a human to type each command. This page
defines how an owner delegates a reviewed provisioning plan to a trusted executor, and
how that delegation is checked.

The provisioning contracts and the GitHub App role catalog are owned by
[`Verjson/verjson-ci`](https://github.com/Verjson/verjson-ci/tree/main/packages/provisioning).
Adopt that package. The sealed self-adoption bootstrap in
[ADR 0169](decisions/0169-sealed-environment-app-bootstrap/README.md) stays retired; it
was scoped to `Verjson/.github` migration and is not a general provisioning route.

## Artifacts

| Artifact | Purpose |
| --- | --- |
| `config/provisioning-delegation-contract.json` | Delegation vocabulary, gated effects, pin, evidence, expiry and revocation requirements, and the activation switch. |
| `config/app-role-custody-inventory.json` | Storage, trust, rotation and proof contract for each of the seven owned GitHub App roles. |
| `scripts/provisioning-delegation-validate.py` | Offline validator that turns a grant document into an authorization receipt. |
| `docs/examples/provisioning-delegation-grant.json` | One worked whole-cohort grant. |

```sh
python3 scripts/provisioning-delegation-validate.py \
  --grant docs/examples/provisioning-delegation-grant.json
```

Exit `0` authorizes the listed actions, `1` withholds authorization and lists the
reasons, and `2` means the documents could not be read. The validator performs no
network call and reads no credential.

## What a grant must establish

- **Issuer and executor boundary.** Only an organization owner issues a grant, and the
  issuer is never the executor. The executor is a named accountable identity, agent or
  human.
- **Stable targets and a complete cohort.** Every target names a `role_id` from the
  custody inventory, declares its repository selection, and lists the selected
  repositories exactly. An incomplete inventory is unknown, never proof that a target
  is out of scope.
- **Effects within the role's ceiling.** A target may request only the effects its role
  permits, and its declared permission ceiling must equal the catalog ceiling. This is
  what preserves review/merge/release separation, keeps `ruleset-audit` read-only,
  isolates runner control, and keeps dependency supersession behind its enablement
  gate.
- **An immutable contract pin.** One 40-hex `Verjson/verjson-ci` commit. A branch or
  tag is rejected.
- **Evidence.** A `sha256` plan digest and a GitHub-hosted review reference with named
  approvers who do not include the executor.
- **Expiry and revocation.** A bounded window no longer than the contract maximum, and
  a GitHub-hosted revocation surface. A revoked or expired grant authorizes nothing.

One reviewed plan authorizes every action it lists. There is no per-call
reconfirmation inside that scope.

## What never establishes authority

Model output, an unattended-mode flag, and an executor-authored approval field are all
rejected. A grant carrying an `approved`, `unattended`, `auto_approve`, or
`model_approval` field fails, as does an unrecognized field: the fixed field set is the
contract. Owner gates stay owner gates — every effect in the contract's
`ownerConsentRequired` list needs its own consent record naming the effect, a
GitHub-hosted reference, and its approvers. Installation and permission changes,
environment configuration, secret write and withdrawal, supersession enablement,
runner registration, governance changes, and new commercial terms are all in that
list. Consent may not exceed the plan either: a consent record for an effect the plan
does not request is rejected rather than banked for later.

## Activation and other organizations

Merging documentation does not activate policy. The shipped contract ships as
`activation.status: defined-not-activated`, so the validator withholds authorization
with reason `contract-not-activated` until an owner flips that status in a reviewed
pull request. A different organization supplies its own policy through
`--contract` and `--inventory`; nothing in the validator is specific to `Verjson`
beyond the documents it is given.

## Role custody inventory

`config/app-role-custody-inventory.json` covers all seven owned roles: `review`,
`merge`, `release`, `renovate-observation`, `dependency-supersession`,
`ruleset-audit`, and `runner-registration`. Each entry records where the credential
lives, the execution trust boundary and prohibited consumers, who may rotate it, and
role-specific positive and negative proof requirements — including which observations
are explicitly *insufficient*. Organization secret metadata presence is insufficient
proof for every environment-only role, and a successful run is insufficient proof for
the audit and runner roles. Rotation is owner-mediated for every role; no role permits
automated key regeneration.
