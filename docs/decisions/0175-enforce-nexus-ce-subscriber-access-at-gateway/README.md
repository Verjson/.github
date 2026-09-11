# 0175 — Enforce Nexus CE subscriber access at the gateway

- **Date:** 2026-09-11
- **Status:** Accepted for implementation and isolated proof; customer activation pending evidence
- **Issue:** [#1186](https://github.com/Verjson/.github/issues/1186)
- **Supersedes:** [ADR 0160](../0160-self-host-paid-package-distribution-on-nexus/README.md)
- **Category:** subscriber authorization, secrets, deployment and recovery — **sensitive class**

## Context

The owner selected the already-paid GitLab CE host, accepted operational ownership,
and ruled out additional paid hosting, Nexus licenses and services. ADR 0160 selected
Pro for subscriber token expiration and a proposed multi-node production topology;
that procurement-dependent decision no longer fits. Preserve it as historical evidence.

The [development service record](../../infrastructure/netcup-nuremberg.md) records
Nexus CE 3.83.0-08 npm/Docker/PyPI publish-and-read smoke tests on 2026-09-07. It does
not establish current patch support, subscriber expiration, revocation, attribution,
restore safety or production availability. Sonatype still documents native user
tokens as Pro-only. We must enforce subscriber lifetime outside CE rather than
rename a permanent Nexus password an expiring token.

Existing internal components provide useful seams, not a deployed subscriber service:

- `verjson-ci` at `6281f2b5ac7c10aafce3fb0862e5f29ccca3aabb` has
  `tools/npm-federation/gateway.mjs`: forge-specific grants and server-side Nexus
  access. Its forge identity checks and publication approvals must remain intact.
- `@verjson/authn` issues authenticated identities; `@verjson/oidc-claims-middleware`
  verifies tokens; `@verjson/authz` supplies authorization decisions;
  `@verjson/identity-lifecycle` supplies revocable session transitions over a
  caller-owned store. None supplies the gateway's durable application state.
- `@verjson/payments` derives entitlements from subscriptions. The application owns
  verified event ingestion, durable projection and reconciliation. Customer-lifecycle
  health observations are not proof of paid entitlement.

## Decision

Use Nexus CE on the existing host behind a **separate subscriber read gateway**.
The subscriber authenticates to the gateway and never receives a Nexus credential.
The gateway mediates every metadata and tarball request. Nexus remains an immutable
artifact store; the application entitlement projection remains the access authority.
The paid scope has no anonymous, proxy/group, direct-origin or storage-URL fallback.

This supersedes the Pro baseline, native subscriber-token choice and proposed Pro HA
topology in ADR 0160. Preserve its privilege separation, immutable byte-identical
publication, per-subscriber migration, rollback and public-publication restrictions
as restated below. Existing development CI does not wait for subscriber migration.

### Identity and entitlement

Issue a unique cryptographically random opaque gateway grant after authenticated
identity, session and entitlement checks. Store only its digest and bound state:
subscriber, permitted package/version policy, entitlement revision, issued time,
absolute deadline and revocation identity. Maximum grant lifetime is 300 seconds,
capped by both session and entitlement expiry. Never place credentials in URLs,
logs, receipts or package metadata. Customer authentication is independent of GitHub;
the proof uses isolated identities, while the production issuer and enrollment
configuration must be supplied and reviewed before activation.

Every request checks current session status, grant status and current entitlement,
including freshness of its authoritative subscription projection. A signed token
or successful earlier request is insufficient. Effective permission is the
intersection of the original grant's package/version scope and current authorized
scope. Narrowing takes effect immediately; an entitlement upgrade or policy change
cannot widen an existing grant and requires fresh issuance for added access.
Stale, missing or unavailable state,
unknown policy, clock rollback or an expired deadline denies access. The application
must define and test its maximum source-reconciliation age; no unbounded stale
"active" subscription can authorize access. Synthetic owner-approved entitlements
are valid only for isolated proof, not production billing authority.

Revoking a subscriber denies new requests after the committed revocation is visible;
the durable store must provide the consistency needed to make that boundary real.
Recheck authorization during active transfers and cancel upstream and downstream
work on expiry/revocation. The initial non-production acceptance target is at most
two seconds from committed revocation to stream termination, with an independent
absolute-expiry timer. Measure it under slow streams and state outages. This is a
proof target, not a production SLA, and already downloaded bytes cannot be revoked.

Refresh/enrollment is separate from npm artifact requests. Restart invalidates all
outstanding gateway grants; restore must also invalidate pre-restore grants and
reconcile current session/entitlement/revocation state before admitting new ones.
An older backup cannot resurrect a revoked subscriber. If current authority cannot
be reconstructed, the restored service stays closed.

### Transport and credential separation

Keep subscriber routes, audience, grant store and read service identity separate
from forge publication. Do not broaden the existing publisher's issuer, manifest,
target or operation allowlists. Reuse maintained transport mechanics at a genuine
seam; do not make a subscriber impersonate a protected forge execution.

Allow only canonical supported npm metadata/tarball GET and HEAD routes. Normalize
once; reject ambiguous encoding, traversal, unexpected query/host/header forms and
unapproved packages/versions. No generic reverse proxy, customer-selected upstream,
admin/API route, write operation or redirect is allowed. Strip incoming identity and
origin-authorization headers. Construct the upstream request from reviewed config.
Filter metadata to authorized versions and rewrite tarball links to the gateway,
preserving artifact integrity. Range, conditional, cached and retried requests must
still be authorized. Metadata and caches must not disclose another entitlement's
packages or return an unguarded origin URL.

Use a distinct Nexus backend identity restricted to necessary browse/read privileges
on the paid hosted repository. It cannot publish, manage identities, run tasks or
administer Nexus. Its secret stays in the maintained organization secret store and
gateway process, outside subscriber/CI job environments. Publication and deployment
administration keep their existing separate identities. Nexus sees the backend
identity; subscriber attribution is established at the gateway, not inferred from
that shared origin principal.

Before activation, prove paid-origin isolation across alternate hostnames, direct
ports, repository/group/member paths and S3 URLs. Preserve unrelated intentionally
public repositories and existing CI paths. Credential concealment alone is not an
origin-isolation proof. A compromised gateway can exercise its read privilege; bound
that blast radius with repository scope, host isolation, monitoring and rotation.

### Attribution and recovery

Persist admission and completion/denial records with server-generated request ID,
opaque subscriber/grant references, entitlement revision, artifact identity,
timestamps, outcome and bytes sent. Reject client-supplied correlation authority.
Correlate gateway requests with Nexus operations without recording secrets. Record
partial/aborted transfers separately from successful downloads. Local durable audit
failure denies admission; independent export has a bounded durable spool and alert
policy that denies further admission before capacity is exhausted. Logs are
operational evidence, not a billing ledger or proof of human intent.

The user is accountable for patching, credentials, capacity, recovery and incident
response. Deploy within the paid host's measured limits; isolate GitLab, Nexus and
gateway resource budgets. This single-host design is not HA. Inventory current
image support and stage patch/rollback verification before customer activation.

Coordinate encrypted database, blob, configuration and necessary key backups using
the exact deployed edition's supported mechanism. Keep independent recovery copies
and audit evidence on already-available capacity; same-host S3 is not independent.
If no such capacity exists, report the concrete gap without buying another service
or silently dropping recovery. Restore into isolation, verify artifact digests and
privileges, reconcile current authorization, invalidate old grants and rotate
restored credentials before exposure. Measure data loss and recovery duration;
production RPO/RTO and availability commitments remain unapproved.

## Implementation ownership and acceptance

The existing [CI PM, #134](https://github.com/Verjson/verjson-ci/issues/134) owns the
isolated subscriber gateway composition, durable application authorization boundary
and executable npm proof. Reuse internal package interfaces; hand concrete defects
back to their existing package PMs rather than duplicating their implementations.
No package change is required merely because it is named in this design.

The existing [CLI PM, #242](https://github.com/Verjson/verjson-cli/issues/242) owns
generated deployment, origin isolation, secret injection proposal, resource bounds
and recovery proof on the existing host. Its deployment proof depends on CI #134.
The canonical PM keeps #1186 open until both receipts and customer acceptance exist.
The ADR merge alone neither deploys a gateway nor proves its security properties.

Use the [acceptance protocol](../../infrastructure/nexus-ce-subscriber-proof.md).
Unit tests must exercise denial boundaries with mocked external dependencies;
integration proof must use the actual gateway, isolated CE instance and real npm
client. Label simulated and live evidence separately. Required failures include
expired/revoked A while B succeeds, an active slow stream, stale state, clock
rollback, origin bypass, malformed paths, unauthorized versions and old-backup
revocation resurrection. Return exact source/image/config hashes and secret-free
receipts. Prior development smoke tests do not satisfy these criteria.

## Migration, gates and rollback

GitHub Packages remains authoritative until a subscriber passes the new proof.
Build one tarball, publish those same bytes to both registries, read both back and
compare integrity/provenance. Before each cutover, authenticate and verify the exact
GitHub Packages rollback version through the intended credential path; canonical
retention is unchanged. Maintain a per-version publication and subscriber ledger.

Tequity migration requires its PM's acceptance and a Tequity-owned gateway credential
in its own secret store. No shared subscriber secret, forced global cutover or early
withdrawal of GitHub access is allowed. Retire the old paid channel only after every
active subscriber has accepted its path and current rollback/recovery evidence.
No public npm publication is authorized; ADR 0152's four proposed public packages
still require individual audits and explicit irreversible-publication approval.

This decision authorizes code, documentation and isolated local proof preparation.
Prepare exact non-production DNS/TLS/network/identity/secret changes and rollback
before requesting the remaining live-operation approval. No additional spend,
production credential grant, customer migration, destructive restore or package
deletion is implied. Do not reopen the settled owner or general budget question.

On failed proof, keep subscriber ingress closed and preserve evidence. After a
cutover failure, verify a subscriber's exact rollback install before revoking its
gateway grant. Never repair a mismatch by overwriting a published version or
restoring stale authorization into service.

## References

- [Sonatype feature matrix](https://help.sonatype.com/en/nexus-repository-feature-matrix.html)
- [Sonatype user tokens](https://help.sonatype.com/en/user-tokens.html)
- [Sonatype logging](https://help.sonatype.com/en/logging.html)
- [Internal identity boundaries](https://github.com/Verjson/verjson-authn/blob/24fe63cab43ccb1652a26d0a2638aecbed536c45/README.md)
- [Existing CI gateway](https://github.com/Verjson/verjson-ci/blob/6281f2b5ac7c10aafce3fb0862e5f29ccca3aabb/tools/npm-federation/gateway.mjs)
