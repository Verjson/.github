# 0152 — Distribute paid packages through Cloudsmith entitlements

- **Date:** 2026-08-28
- **Status:** Accepted
- **Issue:** [#718](https://github.com/Verjson/.github/issues/718)
- **Category:** package distribution, subscriber entitlements, billing — **sensitive class**

## Context

GitHub Packages authorizes repositories and GitHub identities. It does not provide a
subscriber entitlement that Verjson can issue, meter, and revoke independently of a
customer's source-control organization. Cross-organization consumers therefore need a
stored GitHub credential or an App installed in every customer organization. That is a
workable first-party bridge, but it is not the paid product boundary.

The distribution system must provide one revocable read credential per subscriber,
download evidence, private npm support, and no dependency on the subscriber using
GitHub. Contract and configuration packages are adoption surfaces rather than the paid
runtime product and should not require a subscription merely to compile an integration.

## Decision

Use a private Cloudsmith npm repository as the paid `@verjson/*` distribution channel.
Issue one read-only entitlement token per subscriber from the subscription record. Never
share a token between subscribers. Revocation, expiry, package restrictions, and download
limits are entitlement policy; package publication credentials remain separate and must
not be exposed to subscribers or consumer CI.

Cloudsmith download logs and usage metrics are the authoritative artifact-delivery
evidence. Billing may initially remain subscription-based, but the entitlement identity
and measured downloads preserve a later usage-based model. Product billing state owns
token issuance and revocation; neither GitHub team membership nor repository access is
an entitlement source.

Publish this initial adoption surface publicly on npmjs.org:

- `@verjson/identity-contracts`
- `@verjson/graphql-conventions`
- `@verjson/tsconfig`
- `@verjson/eslint-config`

Keep every other `@verjson/*` package subscription-gated until a later issue and ADR
justify moving it to the public adoption surface. A package is not made public merely
because a current customer needs it.

Treat Tequity as the first external subscriber during rollout. Its CI receives a
Tequity-specific Cloudsmith entitlement token through Tequity-owned secret management;
it must not rely on organizational adjacency, a Verjson PAT, or a shared customer token.
The existing customer-owned GitHub Packages credential remains a temporary bridge until
the Cloudsmith path passes installation and revocation canaries.

## Rollout boundary

This decision does not provision a paid Cloudsmith account, accept commercial terms,
publish packages, or write customer secrets. Track those as separate delivery issues
with their owning repositories and human-visible billing and secret-management gates.
Before migration:

1. provision the private npm repository and a non-production subscriber;
2. prove token-scoped install, download attribution, expiry, and revocation;
3. add dual publication with artifact identity checks so GitHub Packages and Cloudsmith
   receive the same package bytes during transition;
4. migrate Tequity with its own entitlement and prove install plus revocation canaries;
5. publish the four public adoption packages to npmjs.org only after package-specific
   license, provenance, and dependency audits;
6. retire GitHub Packages as the paid customer channel only after every active subscriber
   has migrated.

## Consequences

- Subscriber access becomes independently revocable and observable without requiring a
  GitHub account or cross-organization App installation.
- Verjson adds a commercial registry dependency and must reconcile subscription state,
  entitlement state, publishing provenance, and customer-secret delivery.
- Public adoption packages reduce evaluation friction, while runtime libraries remain
  deny-by-default paid artifacts.
- The temporary GitHub Packages bridge remains supported only for the bounded migration;
  it is not a second long-term entitlement model.

## Alternatives rejected

- **Shared GitHub PAT:** cannot isolate or revoke one subscriber and creates a common
  credential blast radius.
- **GitHub App in every customer organization:** couples the product to GitHub and makes
  onboarding an installation project rather than issuing an entitlement.
- **JFrog Artifactory:** capable, but adds a broader platform and operating surface than
  this package-distribution decision requires.
- **Publish every package publicly:** removes entitlement enforcement from the paid
  runtime catalog.

## Rollback

Before any subscriber migration, supersede this ADR without external state to unwind.
After migration begins, keep existing Cloudsmith entitlements valid while reverting
individual consumers to the proven GitHub Packages bridge. Never revoke a subscriber's
only working credential until its rollback install succeeds.

## References

- [Cloudsmith entitlement tokens](https://help.cloudsmith.io/docs/entitlements)
- [Cloudsmith usage metrics](https://help.cloudsmith.io/docs/usage)
