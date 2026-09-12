# Deployment GitHub transport boundary

The generated `scripts/container_deployment_transport.py` supplies authenticated
release-manifest retrieval and representative GitHub canary dispatch. It is a
parent-process capability, not an activated deployment adapter. No reusable
workflow currently invokes it. [Issue #1281](https://github.com/Verjson/.github/issues/1281)
remains blocked by the CLI-owned read-only host export in
[verjson-cli-cloud#504](https://github.com/Verjson/verjson-cli-cloud/issues/504).
The existing controller's child-process and probe interfaces are not yet wired
to this broker. Consequently this delivery does not establish deployment
readiness, rollback readiness, or live acceptance for runner issue #197.

## Request and result contract

Invoke the generated module with `--request <json-path> --output <new-path>`.
The request is strict JSON; unknown, duplicate, missing, stale, and malformed
fields fail closed. `validate_request` is the authoritative schema:

| Fields | Required binding |
| --- | --- |
| `schemaVersion`, `operation` | Version 1; `manifest`, `probe`, or explicitly unavailable `host-export` |
| `attemptId`, `deploymentContractCommit`, `configDigest`, `planDigest` | Deployment run/attempt, immutable contract SHA, admitted configuration digest, approved plan digest (nullable only before plan approval for evidence reads) |
| `action`, `rollbackOfAttempt` | Deploy with null predecessor, or rollback naming a different run/attempt |
| `fleetSelector`, `lane` | Separate fleet and lane identifiers, never interchangeable |
| `issuedAt`, `expiresAt` | Whole-second UTC timestamps; at most 30 minutes and not expired |
| `github` | Exact repository name/ID and dedicated role App/installation IDs |
| `release` | Immutable historical signed-source repository, asset ID, raw manifest digest, variant/image digest, source commit/main ref, canonical signer workflow and immutable signer commit |
| `probe` | Exact runner ID/name/label, unique transaction UUID, workflow ID, reviewed canary tag and commit |

Every operation carries the complete transaction request, including manifest
reads. Preplan evidence reads bind the admitted configuration with a null
`planDigest`; probe dispatch always requires the approved plan digest. The result binds its canonical `requestDigest`. Manifest results preserve
`manifestBytes` verbatim, verify its selected raw digest and parsed release
identity, and invoke `gh attestation verify` with exact repository, source and
reusable signer constraints. The verifier receives only a read token and a fresh
temporary HOME. `github.repository` is the current canonical API repository,
verified through `/repositories/{repositoryId}` against the reviewed stable ID.
`release.repository` is the historical name in the signed source and remains
unchanged in parsed-manifest validation and `gh attestation verify --repo`.
A repository rename must not rewrite historical provenance or rely on a name
alias alone; both identities and the stable ID remain bound in the request. This result is evidence to validate, not an authorization to
mutate a host.

Probe dispatch uses the existing canonical `runner-canary.yml` seven-input
contract and resolves the reviewed tag to the expected commit before dispatch.
It records an exclusive, fsynced adjacent `.dispatch-intent.json` before the
single dispatch POST. The replay baseline and each post-dispatch lookup use a
paginated workflow-run query whose trusted `total_count` must match every
retrieved record, with a maximum of 1,000 records and 40 workflow-run list
requests shared across the baseline and post-dispatch lookups. An incomplete,
over-sized, or over-budget query fails closed; the first 100 records are never
treated as the complete baseline. The transport reserves a lookup before
dispatch and stops polling when the shared request budget is exhausted. The
intent binds the full request, nonce, workflow commit, and pre-dispatch maximum
run ID. Existing output or intent refuses retry.
Polling accepts exactly one matching new run, attempt 1, exact workflow/ref/SHA,
successful representative job, runner ID/name/label, and authenticated artifact.
The ZIP must contain only the fixed receipt filename. Both archive and receipt
digests are verified; the receipt must agree with independent run/job metadata,
the requested release, nonce, timestamps, representative checks and capacity
floors. Receipt equality is type-sensitive: numeric health flags, Boolean run
attempts and floating-point IDs are rejected even when Python would compare
them equal to the expected Boolean or integer. Failed, rerun, replayed, ambiguous, expired or misrouted evidence fails.

An uncertain dispatch or timeout requires parent reconciliation using the saved
intent and authenticated run inventory. There is no automatic redispatch or
automatic cancellation, and this module does not implement transaction resume.
The eventual controller integration must persist and reconcile intents across
resumes before authorizing another probe. `--dry-run` permits only manifest
reads; probe dispatch is rejected before credentials are obtained.

## Authority and provisioning prerequisites

The trusted parent must obtain an explicit short-lived App JWT separately for
each role: `VERJSON_DEPLOYMENT_MANIFEST_APP_JWT` or
`VERJSON_DEPLOYMENT_PROBE_APP_JWT`. There is no ambient `GH_TOKEN`, SSH agent,
HOME configuration, DigitalOcean token or runner-control credential fallback.
The broker validates the live App and installation identities and exact
permissions, then mints and verifies a token scoped to precisely one repository.

| Role | Exact App permissions including implicit metadata |
| --- | --- |
| Manifest | `metadata: read`, `contents: read`, `attestations: read` on the release repository |
| Probe | `metadata: read`, `contents: read`, `actions: write` on `Verjson/.github` |

Installation selection must be `selected`; broader App permissions are rejected
even if a proposed token could be narrowed. The existing runner-control App and
review-publisher Apps are not substitutes. No live identities are invented by
the generator, and this change creates no Apps, keys, environments or policies.

Before workflow wiring, provision reviewed role identities and environment-only
private keys under the main-only environment contract from ADR 0166. The reusable
key-consuming parent job must bind its required role environment and read its key
there directly; callers must not map keys or use `secrets: inherit`. Audit and
remove broader repository/organization key copies through the staged rollout;
environment binding alone cannot prove secret provenance. A protected parent
must mint the JWT, retain it outside all child environments, and enforce the
selected transaction request. Do not forward the JWT or probe write token to
host readers, mutation subprocesses, or manifest-verification children. Manifest
verification receives only the dedicated read token. HTTP redirects never carry
Authorization to artifact storage, and failures suppress credential-bearing
bodies, signed URLs and subprocess stderr.

The controller rechecks every configured runner immediately before retaining the
admitted receipt or invoking a mutating update. Each runner must be online, idle,
admitted to the reviewed group, and carry every configured label and tool. Workload
owned evidence and probe children receive only the adapter environment allowlist
(`PATH`, locale, temporary-directory, and TLS certificate settings). They receive
no `HOME`, SSH agent socket, deployment CLI locator, provider credential, or GitHub
runner-control credential. The deployment CLI child receives its provider and
runner-control credentials explicitly in its separate control environment, and
those values are never forwarded to workload adapters.

## Remaining integration work

CLI v0.29.1 and current main at `de84b4a65faffd9f70178260060901e3743f5de7`
provide no sufficient mutation-free host export. Existing runner inventory
acquires and releases a transaction lock over SSH, so it is not a dry-run
evidence source. Its output also omits required health/tool/drain/lock evidence.
Issue #504 owns the supported export API and its tests; this broker intentionally
rejects `host-export` before reading credentials instead of guessing private
host lifecycle paths or interpreting a mutating inventory as a read.

After #504 lands, the controller integration must construct this complete
request from the admitted configuration and plan; route manifest/probe operations
through the trusted parent; give host readers only explicit reviewed host trust
and read authority; validate export freshness and every host/runner identity;
and bind each baseline's `releaseManifestBytes` to its attested identity. It must
replace the old probe runner/timeout interface and weak receipt boundary rather
than treating this module's existence as an active path. Resume must reconcile
the durable dispatch intent and reject a receipt for another attempt, action,
rollback predecessor, plan, lane, fleet or contract.

The workflow then needs protected issuer environments, required reviewed inputs,
the canonical canary runner-group admission, and generated adopter repinning.
Owner-supplied identities, trusted host access and two authorized healthy hosts
remain live prerequisites. Tests with mocked external boundaries prove protocol
behavior only. Final acceptance still requires real deployment, interrupted
transaction reconciliation and rollback receipts. GitLab remains a future forge
adapter over shared portable mechanics under ADR 0162, without a speculative
shared fleet controller or GitLab CE deployment.
