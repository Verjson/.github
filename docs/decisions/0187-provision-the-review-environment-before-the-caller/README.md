# 0187 — Provision the review environment before the review caller

- **Date:** 2026-09-17
- **Status:** Accepted
- **Related:** [ADR 0094](../0094-arm-required-by-its-own-property-scoped-ruleset/README.md), [ADR 0166](../0166-environment-only-app-private-keys/README.md), [ADR 0180](../0180-environment-only-app-private-keys-for-review/README.md), [ADR 0185](../0185-org-contract-distribution/README.md)
- **Issues:** [Verjson/.github#1401](https://github.com/Verjson/.github/issues/1401)

## Context

`ai-review-merge.yml` takes a required `ai_review_environment` input, documented as the
main-only environment holding the AI review App private key, and three of its jobs run
under `environment: ${{ inputs.ai_review_environment }}`. Under `workflow_call` that
environment resolves in the **caller's** repository, not in this one. ADR 0166 and ADR 0180
made the App private key environment-scoped precisely so it is reachable only from the
default branch.

`scripts/gen-ai-review-caller.sh` emits `with: {ai_review_environment: ai-review-app}`.
Nothing creates that environment. Only this repository has one; no adopter does.

GitHub creates a referenced environment on first use, **with no protection rules**. So an
adopter that installs the generated caller without first creating `ai-review-app` gets a
working review lane and an unprotected environment, and every signal reports success. The
absent control produces no error at all — it is invisible in the run, in the checks, and in
the adopter's configuration until someone reads the environment.

This surfaced while remediating `Verjson/.github#1401`, where four repositories carrying
`verjson-core-checks=enforced` had no review caller and every pull request in them failed
the required arm. The obvious fix — generate the caller and land it — would have silently
created four unprotected environments while closing a visible failure. A remediation that
trades a loud failure for a silent one is worse than the failure.

The existing working adopters do not hit this because they are pinned at `27ede55e`, which
predates the input. They will hit it the moment they advance.

## Decision

**The environment is provisioned before the caller that names it, and its policy is read
back from the API rather than inferred from a passing run.**

Concretely, adopting or advancing the AI review caller is a two-step change in this order:

1. Create `ai-review-app` in the adopter with a custom deployment branch policy naming only
   the default branch, mirroring this repository's:
   `{custom_branch_policies: true, protected_branches: false}`, `protection_rules:
   [branch_policy]`, branch policies `[main]`.
2. Install the generated caller pinned at a reviewed contract SHA.

Verification is a read-back comparison against this repository's `ai-review-app`, field by
field. A green run is not evidence: a green run is exactly what the unprotected case
produces.

Generating the caller remains mandatory — it is never hand-written — and this decision adds
a precondition to that generation rather than changing its output.

## Consequences

- Adopting the review caller is no longer a single-file change, and cannot be performed by
  a bot that only writes files. Environment creation needs repository administration.
- Every adopter still pinned before the `ai_review_environment` input carries this
  precondition as latent work; advancing such a pin without step 1 reintroduces the hole.
  The fleet inventory in ADR 0185 is where that list should come from.
- The generator cannot enforce this on its own. The durable enforcement belongs with the
  adopter audit described in `Verjson/.github#1401`, which should assert environment
  existence and branch policy alongside caller presence, and should assert the caller
  **set** rather than the presence of any member — `verjson-agents` is a live example of a
  half-installed set that satisfies a presence check while the arm still cannot run.
- **An environment created this way is protected but empty, and that is not the declared end
  state.** `config/org-actions-secret-policy.json` records the consumer of
  `AI_REVIEW_APP_PRIVATE_KEY` as *"ai-review-app environment secret of each adopting
  repository"*, with the organization copy classified `environment-only-migration-residue`
  pending withdrawal under ADR 0180. An adopter environment with no secret in it works only
  because the residue copy still resolves through `secrets: inherit`. Completing the
  withdrawal without first placing the key in each adopter's `ai-review-app` breaks every
  review lane provisioned this way. Provisioning the environment is therefore a necessary
  step toward ADR 0166's end state, not an achievement of it, and the key material must be
  placed by whoever holds it.
- The residue copy has meanwhile drifted from its own declared target: the policy requires
  `visibility: selected` limited to `Verjson/.github`, and live metadata reports
  `visibility: all`. `scripts/org-secret-scope-audit.py` already detects this and exits 1 —
  it reports seven such findings — so this is a known, tracked, unactioned state rather than
  a new discovery. It is not addressed here; rotating or rescoping an organization secret is
  destructive and belongs to its owner.

## Related work

- ADR 0166, ADR 0180 — environment-only App private keys.
- ADR 0094 — the arm required by a property-scoped org ruleset, whose coupling fired here.
- ADR 0185 — contract distribution as a version, which is what removes the pin skew above.
- `Verjson/.github#1401` — the fleet break and the durable detection fix.
- `Verjson/verjson-ci#189` — the first application of this ordering.
