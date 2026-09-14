# Portable verjson-ci adoption

`Verjson/verjson-ci` is the canonical implementation for portable, credentialless
Node CI. It owns the versioned contract schema, provider-neutral engine, OCI
runtime, normalized result, GitHub workflow, GitLab component and release
manifest. `Verjson/.github` owns organization governance and publishes the thin
GitHub adapter in `.github/workflows/verjson-ci.yml`.

The adapter is pinned to the complete `verjson-ci` source commit
`c9084daca387849c09f1d97bccf8ac311ff11615`. The image remains a required input
because it must be selected from the same signed complete release manifest as
the schema and adapters; this repository does not invent or float an image tag.

## GitHub organizations

An adopter in any GitHub organization supplies its own contract file and the
image digest from the selected complete release. The caller's repository and
OIDC/check context remain the caller's; the adapter does not assume the
`Verjson` organization or transfer a GitLab credential.

```yaml
name: CI

on:
  pull_request:

permissions:
  contents: read

jobs:
  ci:
    uses: Verjson/.github/.github/workflows/verjson-ci.yml@<reviewed-.github-commit-sha>
    with:
      profile: public-v1
      image: <oci-reference>@sha256:<64-lowercase-hex>
      config: verjson-ci.yml
```

The adopter commits `verjson-ci.yml` with an explicit Node runtime, package
manager, command plan and optional checks. Organization policy and configuration
are separate reviewed references in the onboarding request; the package never
uses a caller-controlled URL or mutable release tag as trust.

## GitLab installations

GitLab components are instance-local. An adopter first mirrors the exact
complete release into a project it controls, verifies the source commit and tag
read back, and then includes the component from that instance:

```yaml
include:
  - component: $CI_SERVER_FQDN/<adopter-group>/verjson-ci/ci@<complete-release-version>
    inputs:
      profile: public-v1
      image: <oci-reference>@sha256:<64-lowercase-hex>
      config: verjson-ci.yml
```

The mirror origin, project path, protected ref and runner policy belong to the
adopting GitLab installation. GitLab `CI_PROJECT_ID`, protected-ref and job
identity claims are verified by the GitLab component/coordinator path; they are
not accepted as GitHub claims. Missing mirror readback, stale tags or a changed
component fail closed.

## Multi-organization and deployment boundaries

| Boundary | GitHub | GitLab |
| --- | --- | --- |
| Source identity | owner/repository, immutable commit and workflow ref | project path/ID, immutable commit and protected ref |
| Execution adapter | this repository's pinned thin facade to `verjson-ci` | adopter-instance component mirrored from the same release |
| Runtime identity | caller-selected OCI digest from the complete manifest | the same digest, pulled under the GitLab installation's policy |
| Credential scope | GitHub token/OIDC stays in GitHub; provider-local environments remain local | GitLab job token/OIDC stays in GitLab; protected variables remain local |
| Governance | `.github` rulesets and required checks | GitLab protected branches/components and local policy |

Portable work runs only after the exact commit, contract, release and image
identities agree. Private dependency acquisition, deployment, signing, merge
authority and organization administration remain explicit provider-specific
lanes. A GitHub-to-GitLab status bridge may compare authenticated receipts, but
it cannot execute repository code with the opposite forge's credential.

## Rollout and rollback

Keep the existing `node-ci.yml` path as the tested GitHub fallback while each
repository runs a shadow/canary comparison. Promote a workload only after
success, failure, timeout, deferred and credential-refusal outcomes match on
both forges and the result binds to the exact GitHub head where required.
Rollback is a caller-side workflow pin/config restoration; no release tag or
image digest is rewritten. The onboarding CLI reports managed-file base and
rollback digests and refuses custom-file conflicts rather than overwriting them.
