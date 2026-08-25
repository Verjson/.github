# 0126 — Split container release Git and package authority

> **2026-08-25 identity note:** ADR 0138 records the existing release App's
> organization-neutral `release-authorization` slug and unchanged authority. Historical
> names below remain unchanged because they describe this decision's accepted state.

- **Date:** 2026-08-24
- **Issue:** [Verjson/.github#1043](https://github.com/Verjson/.github/issues/1043)
- **Extends:** ADR 0078 and ADR 0099

## Context

The container release workflow introduced by ADR 0078 accepts one separately scoped
release token for protected Git writes, GitHub Release creation, GHCR promotion, and
package retention. ADR 0099 subsequently replaced the administrative PAT used by the
canonical changelog release with the dedicated `verjson-release-authorization` App,
but the container workflow retained its older combined credential contract.

That combined contract is now an availability blocker and an unnecessary trust
boundary. No `RELEASE_TOKEN` exists for the runner repository. Provisioning another
long-lived token would restore service by preserving authority that can both mutate
protected Git history and packages. The existing Release App is already the reviewed
ruleset-bypass identity, but its live repository permissions intentionally contain only
Contents write and Metadata read. It must not be widened merely because the old workflow
coupled unrelated operations.

## Decision

The canonical container release workflow splits authority by operation:

- It accepts the role-based `RELEASE_APP_CLIENT_ID` and
  `RELEASE_APP_PRIVATE_KEY` caller contract.
- After candidate, registry, release-state, and attestation validation, it mints a
  short-lived installation token with the immutable
  `actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1`
  action. The request binds `owner` to `github.repository_owner`, `repositories` to
  `github.event.repository.name`, and requests only `permission-contents: write`.
- Only the terminal step that atomically pushes the release commit/tag and creates the
  GitHub Release receives the App token. Checkout does not persist credentials.
- GHCR login, stable-alias promotion, and package retention use only each job's
  repository-scoped `GITHUB_TOKEN` with `packages: write`.
- Candidate artifact/run reads remain on `GITHUB_TOKEN` with `actions: read`;
  attestation and OIDC permissions remain on the promotion job and are never requested
  from the App.
- Generated callers no longer accept or reference `RELEASE_TOKEN` or
  `VERJSON_RELEASE_TOKEN`. They pass only the App Client ID/private-key contract and
  grant the reusable workflow its package permission ceiling.

The App private key remains organization-visible under the adopter-bootstrap decision in
ADR 0125. Repository binding constrains this mint but is not a cryptographic boundary on
a compromised trusted workflow that can read the key; selected-repository installation
or a broker would be required to eliminate that residual fleet-wide trust.

## Consequences

- No long-lived PAT combines protected Git and package-deletion authority.
- The Release App remains Contents-only; package publication does not justify widening it.
- Package writes use GitHub's ephemeral job token and are bounded to the caller repository.
- A missing/malformed App credential or token-mint failure stops before protected Git or
  GitHub Release mutation. Package alias promotion remains restart-safe under ADR 0078's
  preflight and reconciliation contract.
- Every adopter must regenerate its workflow and contract test from the canonical
  generator at the same immutable merge SHA.

## Verification

The semantic contract test rejects repository or permission widening, mutable token-mint
actions, App-token delivery outside the terminal step, persisted checkout credentials,
registry use of the App token, and either legacy PAT name. A disposable release canary
must prove ruleset bypass, GHCR publication, immutable Git/GitHub Release state, and
cleanup before any held adopter rollout merges.
