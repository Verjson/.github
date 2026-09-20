# 0197 — Use Pulumi for the GitLab mirror artifact

- **Date:** 2026-09-20
- **Status:** Accepted
- **Issue:** [Verjson/.github#1514](https://github.com/Verjson/.github/issues/1514)
- **Implementation:** [Verjson/verjson-ci#200](https://github.com/Verjson/verjson-ci/issues/200)
- **Category:** infrastructure tooling and release contract
- **Supersedes:** [ADR 0162](../0162-unify-portable-ci-engine-and-forge-adapters/README.md)
- **Related:** [ADR 0027](../0027-pulumi-preview-credential-boundary/README.md)

## Context

ADR 0162 made `Verjson/verjson-ci` the canonical distribution for the portable CI engine and its GitLab mirror kit. The completed `verjson-ci#14` delivered that kit with a Terraform module. The module, its validation workflow, documentation, and release manifest still identify Terraform as an active implementation.

The owner has confirmed that infrastructure for the managed Verjson repository family is to be built with Pulumi. Retaining a Terraform module in the canonical release would contradict that platform direction and introduce a second infrastructure toolchain alongside existing Pulumi programs and controls.

## Decision

1. The GitLab mirror kit in `Verjson/verjson-ci` will be implemented and exercised with Pulumi. Its Pulumi program remains part of the same canonical repository and release line as the mirror synchronization tool.
2. Preserve the mirror's existing guarantees: it mirrors immutable unprefixed SemVer tags, preserves the exact source Git objects and commits, refuses rewrites, protects destination tags, keeps credentials out of source and plaintext state, and emits verifiable synchronization evidence.
3. Use the repository's supported Pulumi workflow and credential boundary from ADR 0027. Provider credentials and backend access are runtime inputs; untrusted validation receives neither. Pulumi state and outputs must not expose credentials. Do not add a Terraform fallback.
4. Keep released manifest schema v1 and its already-published artifacts immutable. Publish the Pulumi artifact through a new manifest schema version with explicit Pulumi paths and digests. Adapt consumers to the new schema; retain v1 parsing only where needed to verify existing releases. Never describe the old Terraform artifact as Pulumi or rewrite a released manifest.
5. Validate the program with provider-mocked behavioral tests and an isolated GitLab CE exercise before release. Tests must prove tag protection, identity preservation, refusal of tag rewrites, credential redaction, and failure handling. A test or issue does not authorize a production update; any live migration requires a separately authorized target and credentials.

## Consequences

- Pulumi becomes the only supported IaC implementation for the GitLab mirror kit in this repository family.
- The published release manifest has a deliberate schema transition. Consumers must adapt before adopting a release that carries the Pulumi artifact.
- Existing Terraform artifacts and release notes remain historical. They are not updated or represented as Pulumi.
- Any discovered live Terraform-managed mirror state must be inventoried and safely adopted or retired before a production cutover; this ADR alone does not authorize either action.
