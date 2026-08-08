# 0078 — Container releases promote immutable candidates before protected deployment

- **Date:** 2026-08-08
- **Issue:** [#626](https://github.com/Verjson/.github/issues/626)
- **Follow-ups:** [#628](https://github.com/Verjson/.github/issues/628), [#627](https://github.com/Verjson/.github/issues/627), [#629](https://github.com/Verjson/.github/issues/629)
- **Category:** release authority, production credentials, and runner deployment — **sensitive class**
- **Status:** Accepted

## Context

Runner images currently move from a merge to a registry publication without an
organization contract distinguishing a candidate, a stable release, and a production
deployment. A mutable tag can therefore look deployable even though it names no
independently authorized release. The operator-driven DigitalOcean rollout also lacks a
portable receipt binding the deployed fleet to the exact attested image set.

This decision resolves [#626](https://github.com/Verjson/.github/issues/626). The
implementation is deliberately split into immutable candidate publication
([#628](https://github.com/Verjson/.github/issues/628)), exact-digest stable promotion
([#627](https://github.com/Verjson/.github/issues/627)), and protected deployment
([#629](https://github.com/Verjson/.github/issues/629)). Consumer adoption remains a
separate change in `Verjson/verjson-github-runner`; this repository does not edit that
consumer.

## Decision

The organization adopts this one-way lifecycle:

```text
pull-request validation
  -> immutable main candidate
  -> explicitly promoted stable release
  -> independently approved production deployment
  -> one canary
  -> sequential fleet rollout or manifest-based rollback
```

Each transition consumes the signed receipt from the preceding transition and emits a
new retained receipt. No transition rebuilds an image.

### Version and image identity

Each consumer commits a reviewed release configuration containing one exact
`nextStableVersion`. It is a `MAJOR.MINOR.PATCH` SemVer greater than the latest stable
release. Changing the next stable line therefore passes through the consumer's normal
pull-request controls; a workflow input or an arbitrary branch cannot select it.

A successful build of the consumer's default branch has the SemVer prerelease identity
`<nextStableVersion>-rc.<run_id>.<run_attempt>`. The GitHub run ID and attempt are numeric,
so the identity is valid SemVer and unique across reruns. The candidate receipt binds
that identity to the default-branch commit, workflow identity, run, complete declared
variant/platform matrix, OCI index digests, platform manifest digests, and provenance.
Candidate artifacts and receipts are append-only. A rerun may reconcile byte-identical
state but must fail on any identity or digest mismatch.

Stable SemVer is created only by an explicit dispatch from the consumer's protected
default branch. The requested stable version must equal the candidate's recorded
`nextStableVersion`. Promotion copies or retags the exact candidate digest set and emits
an immutable release manifest conforming to
[`release-manifest.schema.json`](./release-manifest.schema.json). It does not invoke a
Dockerfile, Bake, or build command. Every declared variant and platform is verified
before the signed release manifest is published; a missing, extra, unattested, or
divergent digest fails the release without partial promotion. Registry aliases never
constitute promotion: the signed, complete manifest is the sole authoritative stable
release record.

Convenience tags such as `candidate`, `stable`, a major line, or `latest` may remain for
humans and development tools. They are mutable aliases, are excluded from manifests,
and are never accepted as release or deployment inputs. Automation resolves only
manifest-recorded `sha256` digests.

### Independent deployment and rollback

Production deployment is a separate explicit dispatch that accepts an immutable release
manifest identity, revalidates its signature/provenance and complete digest set, and
waits at the consumer repository's protected environment named `production`. The
credential-bearing reusable job names that canonical environment directly; neither a
caller input nor a manifest can override it. Release authority does not imply deployment
authority. A merge and a stable promotion cannot bypass that human-visible environment
approval.

The generated contract and its preflight fail closed unless all of these are true:

- the dispatch ref is exactly the protected default branch and the `production`
  environment admits protected branches only;
- the environment has at least one required reviewer, prevents self-review, and disables
  administrator bypass;
- the completed environment review names a reviewer different from the workflow
  dispatcher; and
- only the reusable workflow's post-approval mutation step receives the consumer
  environment secret named `VERJSON_RUNNER_DEPLOY_TOKEN`. The generated caller cannot
  pass a token, `secrets: inherit`, an environment name, or an alternate secret name.

The preflight verifies those settings through the GitHub API before the reusable job can
reach production credentials. The adopter contract test rejects a caller/workflow shape
that weakens any invariant, and the deployment receipt records the dispatcher, actual
reviewer, workflow run, and environment protection rule used. The fail-closed policy is
executable as `scripts/container_deployment_preflight.py`; #629 wires normalized GitHub
API evidence into that pinned validator rather than reimplementing the decisions in
workflow shell.

`previousRelease` in a release manifest is the immutable predecessor in the stable
release line. It is not fleet state and never changes after promotion. Immediately before
mutation, deployment independently observes the fleet, verifies that it agrees with the
last successful deployment receipt, and records that baseline as
`observedDeployedRelease` in an immutable receipt conforming to
[`deployment-receipt.schema.json`](./deployment-receipt.schema.json). An unexpected fleet
baseline is drift, not an implicit upgrade path.

After approval, the deployment controller selects one explicitly configured canary from
the target environment. It admits only an online, idle runner, updates it through
`verjson-cli-cloud`, and runs the consumer-owned representative probe. The observation
window and success criteria are committed consumer inputs. Only a passing canary permits
the remaining runners to update one at a time in a deterministic order, with readiness
and the same representative probe checked after each update. The first interruption,
timeout, digest mismatch, or probe failure stops the rollout; it never skips a failed
runner or continues in parallel.

Rollback is an independently approved deployment of the exact
`observedDeployedRelease` manifest recorded in the current successful deployment
receipt. It neither rewrites the target release manifest nor rebuilds an image; it
revalidates that retained manifest and provenance and follows the same canary and
sequential protocol. If no verified previous manifest is retained, automation fails
closed and an operator must resolve the missing evidence; a mutable tag is not a
recovery mechanism.

### Ownership and credential boundary

- `Verjson/.github` owns reusable policy, schemas, generated callers, contract tests,
  attestation gates, approval sequencing, receipt formats, and rollback protocol.
- Consumer repositories own Dockerfiles, Bake targets, registry image names, variant and
  platform matrices, smoke probes, next-stable configuration, target environments, and
  thin generated callers pinned to immutable contract commits.
- `verjson-cli-cloud` owns runner update mechanics, idle/readiness enforcement, digest
  verification on the target, and its safety invariants. Workflows orchestrate that CLI;
  they do not reproduce its behavior in shell.
- Each consumer's protected GitHub environment owns its narrowly scoped production
  credential and approvers. Its `VERJSON_RUNNER_DEPLOY_TOKEN` authorizes only the named
  consumer fleet operations required by `verjson-cli-cloud`, not account-wide resource
  creation or unrelated environments. `Verjson/.github` stores no broad DigitalOcean
  credential, reusable workflows receive no organization-wide production secret, and
  candidate or release jobs receive no deployment credential.

The environment, credential scope, and production approver rule are mandatory human
review points for every adopter. Changing them is sensitive work and requires a consumer
ADR or a superseding organization decision. Creating capacity or incurring DigitalOcean
spend remains an explicit operator action and is outside this contract.

### Generated callers and contract versions

Adopters do not copy workflows. Each of the three lifecycle stages is a separately
versioned contract: candidate publication, container release, and runner deployment.
Their thin callers are generated from an immutable `Verjson/.github` contract commit and
pin the reusable workflow at that same commit. A candidate-contract update does not
silently move a deployment contract; adopters regenerate and review each selected stage.

The implementation follows the canonical changelog precedent: use
`Verjson/.github/scripts/gen-changelog-caller.sh` for the repository's changelog
workflow, renderer, and contract-test outputs, all at one immutable contract SHA.
Handwritten substitutes are forbidden. The container delivery follow-ups add a dedicated
generator whose output set contains the selected thin workflow caller, a manifest
renderer/validator, and an adopter contract test. Every file in one generated output set
records and enforces one immutable contract SHA; a mixed pin or edited generated file
fails the contract test. The generator itself never writes consumer credentials or
environment approvers.

Schema validation is necessary but cannot express uniqueness by object property. Every
candidate and release therefore also runs `scripts/container_release_manifest.py`
against the protected default branch's reviewed consumer configuration. It rejects
duplicate image variants, duplicate `(os, architecture, variant)` platform identities,
and any missing, extra, or substituted repository, variant, platform, provenance
predicate, or builder identity. The generated contract test must invoke this pinned
validator; a schema-only check is not a valid implementation.

The release manifest has its own integer `schemaVersion`. Incompatible receipt changes
increment that version and reusable workflows reject unsupported versions. Workflow
contract pins and manifest schema versions are related evidence but are not conflated.

### Audit retention

Candidate receipts, release manifests, deployment receipts, and rollback receipts are
uploaded as immutable attestations and retained according to the consumer's release
retention policy. The stable release keeps its manifest alongside the release record;
deployment and rollback receipts record the environment, approver-visible workflow run,
selected manifest, per-runner before/after digest, probe result, and timestamps. Retention
must cover the currently deployed release and its previous verified release, so rollback
does not depend on an expired workflow artifact.

## Threat model

| Threat | Required control | Failure behavior |
| --- | --- | --- |
| Mutable or replaced tag | Deploy only schema-validated `sha256` digests from a verified release manifest; tags are display aliases | Reject tag inputs and digest disagreement |
| Digest substitution | Bind variant, platform, digest, source run, and provenance identity in signed receipts; resolve registry state again at each transition | Stop before promotion or mutation |
| Untrusted caller input or arbitrary branch | Require the exact protected default branch; validate caller repository, workflow pin, schema, and the complete matrix against reviewed configuration with the semantic validator | Reject before credentials or write permission are available |
| Broad or leaked production credential | Keep a least-privilege credential only in the consumer production environment and grant it solely to the deployment job after approval | Candidate/release jobs cannot authenticate to production |
| Environment bypass or self-approval | Preflight requires protected-branch admission, a required reviewer distinct from dispatcher, self-review prevention, and disabled admin bypass; the generated caller cannot override the environment | No credential-bearing job without independent environment approval |
| Duplicate matrix identity | Semantic validation rejects duplicate variant and platform tuple keys before comparing the exact reviewed matrix and provenance identities | Reject before promotion or deployment |
| Partial promotion | Verify the complete declared matrix before publishing stable references and make publication restart-safe against exact existing state | Fail without a partially authoritative release |
| Rollout interruption | Update one runner at a time, retain per-runner receipts, and stop on the first non-success | Preserve known state and require resume or approved rollback |
| Rollback drift | Bind the observed fleet predecessor in the deployment receipt, roll back by that retained manifest, revalidate provenance, and verify each target digest | Fail closed if fleet state, evidence, or exact artifacts disagree |
| Compromised reusable caller | Generate callers and contract tests together at one immutable contract SHA; reject edits and mixed pins | CI blocks the consumer change |
| Compromised update implementation | Keep safety invariants in `verjson-cli-cloud` and require its provenance enforcement before deployment adoption | #629 remains blocked until the upstream invariant exists |

The highest-blast-radius review points are the production environment binding, secret
scope, manifest-to-digest validation, and the call into `verjson-cli-cloud`. These retain
a human gate even after the generated contract is established.

## Migration plan for `Verjson/verjson-github-runner`

1. Land #628 and generate the candidate caller at an immutable contract SHA. Commit the
   reviewed next-stable line and declared matrix. Wire the schema plus semantic validator
   into the generated contract. Preserve the current digest receipt as
   source evidence while dual-writing the new candidate receipt; disable any appearance
   that a merge publishes stable state. A merge may publish only an immutable candidate.
2. Compare the new receipt's complete variant/platform digests with the existing build
   receipts before retiring the old receipt shape. Do not infer equivalence from tags.
3. Land #627 and generate the release caller at its immutable contract SHA. Exercise an
   explicit promotion of one retained, attested candidate in a non-production namespace,
   proving that the build does not run and an incomplete matrix publishes nothing.
4. After the upstream `verjson-cli-cloud` provenance-enforcement dependency is available,
   land #629 and generate the deployment caller. Configure the protected production
   environment with protected-branch-only admission, self-review prevention, required
   independent reviewers, and admin bypass disabled. Scope `VERJSON_RUNNER_DEPLOY_TOKEN`
   to the named fleet, then configure the canary, observation window, probes, and
   deterministic fleet order in the consumer repository.
5. Perform a protected canary deployment, sequential rollout, induced-stop exercise, and
   approved rollback to the recorded previous manifest. Retain all receipts. Only then
   remove the legacy operator path and old receipt reader.

No step changes an unmanaged consumer repository from this ADR PR. Each adoption step is
reviewable and reversible before the production dispatch; the production environment
approval remains an explicit hold on the live mutation.

## Consequences

Merges can continue producing useful candidates without claiming release or deployment
authority. Stable versions become coherent promotions of already attested bytes, and a
production fleet can be explained from retained manifests and receipts. The cost is a
three-stage generated contract and additional retained evidence. Promotion and rollout
take longer because completeness, approval, canary observation, and sequential probes
are deliberate gates.

GHCR remains the initial registry. This decision neither selects a replacement registry,
reimplements runner updates, nor grants permission to add fleet capacity or spend.
