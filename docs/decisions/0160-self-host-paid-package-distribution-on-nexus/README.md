# 0160 — Self-host paid package distribution on Sonatype Nexus Repository

- **Date:** 2026-09-01
- **Status:** Accepted for design and non-production proof only
- **Issue:** [#1186](https://github.com/Verjson/.github/issues/1186)
- **Supersedes:** [ADR 0152](../0152-distribute-paid-packages-through-cloudsmith/README.md)
- **Category:** package distribution, subscriber authorization, credentials, and recovery — **sensitive class**

## Context

ADR 0152 selected Cloudsmith before any account was provisioned or subscriber was
migrated. The owner has replaced that direction with self-hosted **Sonatype Nexus
Repository**. ADR 0152 remains the immutable record of the abandoned decision; this ADR
replaces it.

The paid distribution boundary still needs private npm hosting, one independently
revocable identity per subscriber, least-privilege reads, attributable downloads, a
reconcilable entitlement inventory, and no requirement that a customer use GitHub. A
self-hosted registry adds direct responsibility for identity, availability, storage,
patching, logs, backup, and disaster recovery.

Sonatype's documentation available on 2026-09-01 confirms that both current Community
Edition (CE) and Pro support npm hosted repositories, custom access controls, content
selectors, LDAP, REST APIs, S3 blob stores, external PostgreSQL, and backup/restore.
However, **user tokens, token expiry, high availability, resilient deployment options,
SAML, export-assets tasks, and vendor support are Pro capabilities**. CE also has documented
usage limits. The self-hosted request log contains authenticated user ID, client IP, request
path, status, bytes, and latency, but the built-in audit log records configuration and
asset changes rather than establishing a subscriber-download ledger by itself.

These are documentation findings, not a licensed-environment proof. Sonatype can change
edition packaging, licensing, limits, and APIs. The exact product build, license, support
terms, request-log format, token behavior, and export surfaces therefore remain
pre-provisioning acceptance gates.

## Decision

Use a private, self-hosted Nexus npm **hosted** repository as the future paid
`@verjson/*` distribution system of record. Keep an npm proxy/group repository separate
from the paid hosted repository so subscriber roles cannot accidentally inherit broader
access through a transitive group. Anonymous access is disabled.

Select **Nexus Repository Pro as the production baseline, subject to procurement and
non-production verification**. Its documented user-token expiry and supported HA options
fit the credential-lifetime and availability requirements without inventing those controls
outside the product. No purchase is authorized by this decision. If current commercial
terms or a proof deployment disproves a required capability, stop and reopen the edition
and topology decision; do not silently fall back to CE.

The initial topology is one non-production node for bounded proof. The proposed production
topology is multiple Pro nodes behind a TLS-terminating reverse proxy/load balancer, using
a separately operated external PostgreSQL database and shared encrypted blob storage.
Production topology, provider, region, RPO, RTO, capacity, availability target, and support
plan are outputs of a later provisioning proposal and human gate, not facts asserted here.

### Authorization and credential boundaries

- Product billing state is the entitlement source. Nexus roles are a reconciled
  enforcement projection, never the billing system of record.
- Each subscriber receives its own identity and read-only role scoped to the paid npm
  repository (or an even narrower content selector proven to work for scoped npm package
  metadata and tarballs). No credential is shared between subscribers.
- Subscriber identities get only `browse` and `read`; they cannot add, edit, delete,
  administer, search outside the intended surface, or access repository members directly.
- Publication uses a distinct non-human service identity with the minimum `add`/`edit`
  privileges needed for immutable-version npm publication. It has no administration,
  user-management, backup, or log-export authority.
- Entitlement reconciliation uses a separate automation identity that may create, disable,
  and role-map subscriber identities but cannot download or publish packages. Its exact API
  privileges must be proven; wildcard administration is rejected.
- Administrative access is human, individually attributable, protected by the selected
  enterprise identity control, and unavailable to customer CI. Break-glass credentials are
  offline, monitored, rotated after use, and tested without becoming routine automation.
- Backup operators can read encrypted backup material but cannot authenticate to repository
  content. Restore operators receive time-bounded access only during an approved exercise
  or incident.
- Pro user tokens are the preferred subscriber secret only after the proof demonstrates
  npm compatibility, bounded lifetime, individual deletion, and attribution. A local-user
  password is not an acceptable production substitute. If tokens cannot meet those tests,
  an external identity/gateway design needs a new ADR.

### Threat model and required controls

| Threat | Boundary and required control | Proof required before production |
|---|---|---|
| Stolen subscriber secret | One read-only, subscriber-specific, expiring token; secret in the subscriber's manager; immediate individual deletion; no shared fallback | Install succeeds before expiry; the same token fails after expiry/deletion; another subscriber remains unaffected |
| Subscriber privilege escalation | Deny-by-default role and repository/content-selector scope; no anonymous, UI administration, write, delete, task, API, or transitive group privileges | Negative API, direct-member, publish, overwrite, and delete tests return denied |
| Publisher compromise | Dedicated write identity; no read-customer, identity, admin, backup, or log privileges; protected release environment; immutable version policy | Exact allowed publish succeeds and overwrite, user management, and repository administration fail |
| Administrator compromise | Individual enterprise identities, phishing-resistant authentication where supported, network restriction, audited changes, offline break glass | Login and role-change audit is exported; break-glass rotation exercise completes |
| Reconciler compromise | Narrow identity-management API scope, desired-state diff, two-person approval for mass revoke/grant, immutable receipts | Reconciliation can affect one test subscriber but cannot read or publish content |
| Log loss or misleading attribution | Preserve reverse-proxy and Nexus request logs with trusted time, authenticated principal, path, status, and bytes; ship append-only off-host; reconcile with entitlement inventory | Known installs produce complete, uniquely attributable records; parser handles rotations/retries and rejects gaps |
| Backup theft or corruption | Encrypt in transit and at rest with separately managed keys; immutable/off-site copies; coordinated database/blob/config/node-ID backup; access logs | Restore into isolated environment, integrity-check package bytes and RBAC, rotate restored secrets before exposure |
| Registry or dependency substitution | HTTPS only, controlled DNS, repository separation, package allowlist, byte/provenance comparison, no silent proxy fallback for paid scope | Expected package succeeds; namespace-confusion and tampered bytes fail closed |
| Node, database, storage, or region loss | Monitored capacity, documented maintenance, consistent backups, tested restore, and later approved HA/DR topology | Recovery exercise meets the approved RPO/RTO and serves verified artifacts |
| Vulnerable or unpatched Nexus/reverse proxy | Supported versions, inventory/SBOM, advisory intake, staged patch canary, emergency patch path, least exposed network surface | Upgrade and rollback rehearsal plus vulnerability scan evidence |
| Destructive operator action | Separate duties, protected changes, tested backups, immutable release versions, and receipts for deletes/retention changes | Unauthorized destructive operations fail; approved recovery restores the removed test artifact |

Request logs can supply operational attribution, but they are not billing-grade evidence
until completeness, identity stability, retries, retention, time synchronization, and export
are proven. Usage-based billing requires a separate decision. The default documented
90-day log retention is not adopted implicitly; legal/privacy and operational owners must
approve a retention period before production.

### Operating ownership before provisioning

| Surface | Accountable owner | Required operating contract |
|---|---|---|
| Nexus application and reverse proxy | Platform operations | Harden, patch, canary upgrades, monitor health/latency/errors, manage maintenance and rollback |
| DNS and TLS | Platform operations with security approval | Controlled zone changes, automated certificate renewal, expiry alerting, HTTPS-only ingress, origin restriction |
| Identity, roles, tokens, break glass | Security | Least-privilege templates, issuance/revocation SLA, access review, break-glass custody and audit |
| Entitlement reconciliation | Product billing owner | Desired-state source, idempotent diff, grant/revoke receipts, mismatch alerting, customer lifecycle ownership |
| Publication and provenance | Release engineering | Protected publisher identity, immutable version policy, byte/provenance receipts, dual-publication monitoring |
| PostgreSQL, blob storage, encryption keys | Platform operations | Capacity thresholds, encryption, consistent snapshots, retention, key rotation and access logs |
| Logs and evidence | Security/operations | Off-host collection, integrity, redaction, approved retention, query/export and gap alerts |
| Backup, restore, and disaster recovery | Platform operations with service owner | Approved RPO/RTO, off-site copies, restore runbook, scheduled exercises, incident communication |
| Customer credential installation and cutover | Customer-owning PM | Customer-owned secret destination, acceptance window, rollback proof, support and revocation confirmation |
| License, support, privacy, and spend | Human owner/procurement | Current edition limits, price, support/SLA, data region, log/privacy terms and exit plan |

An owner name, escalation path, on-call expectation, and approved RPO/RTO/availability
target must replace each role label in the provisioning proposal. An unowned row blocks
production.

## Non-production proof plan

The proof uses synthetic packages and identities in a bounded, disposable environment. It
may use a time-limited Pro trial only after a human accepts its terms; this ADR itself does
not start a trial or provision infrastructure.

1. Pin and record the exact Nexus build, edition/license, deployment manifest, database,
   blob store, reverse proxy, and configuration hashes. Record observed edition limits.
2. Create separate admin, publisher, reconciler, subscriber A, subscriber B, backup, and
   restore identities. Export the effective privilege matrix and exercise every negative
   boundary in the threat model.
3. Publish a synthetic scoped npm package. Install it through the supported npm client with
   subscriber A. Correlate package/version/tarball requests to A in off-host request logs
   without recording token material.
4. Prove the configured token lifetime and individual deletion. Require A to fail after
   expiry/deletion while B still installs. Measure revocation propagation and define its SLA.
5. Exercise entitlement reconciliation: create, narrow, disable, re-enable, and remove one
   synthetic subscriber; prove idempotence and deny mass change without approval.
6. Attempt anonymous download, direct repository-member access, cross-scope reads, publish,
   overwrite, delete, task execution, user management, and log access from each unprivileged
   identity. Every unexpected success fails the proof.
7. Back up database, blobs, configuration, node identity, encryption material, and required
   logs consistently. Restore into an isolated endpoint; verify RBAC and artifact digests,
   rotate restored secrets, and measure RPO/RTO.
8. Rehearse patch, failed patch rollback, storage pressure, database loss, node loss, expired
   TLS, log-export failure, and denied-DNS scenarios. Confirm alerts and runbooks.
9. Produce a signed, secret-free proof receipt containing build/edition, configuration and
   artifact digests, test results, attribution/revocation latency, backup/restore measurements,
   outstanding risks, and no credentials or customer data.

Failure of any proof leaves GitHub Packages authoritative and blocks provisioning.

## Migration and provenance

Migration is per version and per subscriber; it is not a registry-wide flag day.

1. Inventory active subscribers and supported package/version closures. For every intended
   cutover, authenticate to GitHub Packages through the same credential path the rollback
   will use and prove the exact rollback version remains readable under canonical retention.
2. The protected release job builds or retrieves one canonical npm tarball, records its
   SHA-256 digest plus source/tag provenance, and publishes **those same bytes** to GitHub
   Packages and Nexus. Rebuilding separately for each registry is prohibited.
3. Read back both registry tarballs and compare digest, package name, version, integrity,
   provenance linkage, and runtime dependency closure. A mismatch fails closed and does not
   produce a migration candidate.
4. Maintain a version-keyed dual-publication ledger with registry receipts and reconciliation
   alerts. Never place publisher or subscriber credentials in the receipt.
5. Migrate Tequity only after its owning PM accepts the handoff and installs a
   Tequity-specific read credential in Tequity-owned secret management. Run install,
   attribution, expiry/revocation, and rollback canaries in the agreed window.
6. Migrate later subscribers independently with the same evidence. Keep GitHub Packages
   publication/read support until every active subscriber has a tested Nexus path and a
   currently readable rollback version.
7. Retire GitHub Packages as the paid channel only through a later, explicit human-approved
   change backed by a zero-unmigrated-subscriber inventory and successful restore exercise.

ADR 0152's proposed public adoption packages — `@verjson/identity-contracts`,
`@verjson/graphql-conventions`, `@verjson/tsconfig`, and `@verjson/eslint-config` — are
**not approved for public publication by this decision**. Each must be re-audited for
license, secrets, provenance, and a complete runtime dependency closure containing no gated
package. Publishing any package to npmjs.org requires a package-specific human
acknowledgement that released bytes cannot be made private again.

## Human gates

The following actions remain stopped until a human approves the exact target, evidence,
cost, and rollback:

- accepting a Pro trial or commercial terms, incurring spend, or provisioning any
  infrastructure;
- selecting a production provider/region/topology or committing to an SLA, RPO, or RTO;
- creating or mutating DNS, TLS, firewall, identity-provider, encryption-key, or secret
  state;
- granting production administration, publication, reconciliation, backup, or subscriber
  credentials;
- migrating any customer, changing its registry configuration, or revoking its existing
  GitHub Packages path;
- retiring GitHub Packages or deleting registry, log, backup, or entitlement state; and
- publishing any package to public npmjs.org, which is irreversible disclosure.

Documentation, mocked automation, disposable local tests, and an approved non-production
proof may proceed without crossing these gates. A proof environment that itself incurs
spend, accepts terms, writes managed DNS/secrets, or uses customer data still requires the
corresponding gate.

## Consequences

- Verjson owns the registry's security, availability, evidence, and recovery rather than
  delegating them to Cloudsmith.
- Subscriber credentials remain independent of GitHub and individually revocable, subject
  to the Pro capability proof.
- Production requires a Pro commercial decision unless a later ADR supplies an equivalent
  external identity/gateway design and re-proves availability and recovery on CE.
- Dual publication costs operational effort but preserves a tested per-subscriber rollback
  until Nexus is proven.
- Download attribution begins as operational evidence, not a billing ledger.

## Alternatives rejected

- **Cloudsmith entitlements:** explicitly replaced by the owner before provisioning; ADR
  0152 preserves the rationale of that former choice.
- **Nexus CE plus permanent local passwords:** avoids license spend but loses documented
  user-token expiry and supported HA, expanding secret and availability risk.
- **Shared subscriber credential:** prevents individual attribution and revocation and
  creates a common blast radius.
- **GitHub Packages as the permanent paid boundary:** couples subscribers to GitHub
  identities/credentials and remains unable to model product entitlement directly.
- **Immediate public npm publication:** removes the paid boundary and irreversibly discloses
  bytes before package-specific audits.

## Rollback

Before customer migration, supersede this ADR and discard the non-production environment;
GitHub Packages remains authoritative. During migration, roll back one subscriber at a time
to the exact GitHub Packages version proven readable immediately before cutover. Do not
revoke the Nexus credential until the rollback install succeeds, and do not revoke the
GitHub credential until the Nexus acceptance and rollback windows close.

If Nexus publication mismatches GitHub bytes, quarantine that Nexus version, keep consumers
on GitHub Packages, rotate the publisher if compromise is suspected, and reconcile from the
canonical provenance receipt. If Nexus loses availability or integrity, stop new cutovers,
restore into isolation, validate package digests and RBAC, rotate restored secrets, and only
then return it to service. Public npm disclosure cannot be rolled back; only later versions
can be stopped or corrected.

## References

- [Sonatype: self-hosted Nexus Repository feature matrix](https://help.sonatype.com/en/nexus-repository-feature-matrix.html)
- [Sonatype: configuring npm](https://help.sonatype.com/en/configuring-npm.html)
- [Sonatype: repository types](https://help.sonatype.com/en/repository-types.html)
- [Sonatype: privileges](https://help.sonatype.com/en/privileges.html)
- [Sonatype: user tokens and expiration](https://help.sonatype.com/en/user-tokens.html)
- [Sonatype: user token API](https://help.sonatype.com/en/user-tokens-api.html)
- [Sonatype: logging](https://help.sonatype.com/en/logging.html)
- [Sonatype: auditing](https://help.sonatype.com/en/auditing.html)
- [Sonatype: backup preparation](https://help.sonatype.com/en/prepare-a-backup.html)
- [Sonatype: resiliency and high availability](https://help.sonatype.com/en/resiliency-and-high-availability.html)
- [Sonatype: high-availability deployment](https://help.sonatype.com/en/high-availability-deployment.html)
- [Sonatype: reverse proxy guidance](https://help.sonatype.com/en/run-behind-a-reverse-proxy.html)
