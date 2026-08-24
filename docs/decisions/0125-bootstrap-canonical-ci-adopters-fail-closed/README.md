# 0125 — Bootstrap canonical CI adopters through a fail-closed manifest

- **Date:** 2026-08-24
- **Status:** Accepted
- **Issue:** [#1037](https://github.com/Verjson/.github/issues/1037)
- **Category:** Credentials, GitHub Apps, and organization CI policy (sensitive class)
- **Extends:** [ADR 0123](../0123-use-organization-neutral-ci-variables/README.md)

## Context

An organization adopting the canonical CI package must coordinate organization
variables, write-only Actions secrets, GitHub App identities and installations, and
generated repository callers. These settings span APIs with different read-back
properties. In particular, Actions secret values cannot be read after upload, and the
ordinary GitHub REST API cannot idempotently create a GitHub App or generate its
private key. Treating an absent read-back value as proof, or silently widening an
existing App, would turn a bootstrap convenience into an authority escalation path.

## Decision

The canonical bootstrap consumes one versioned JSON manifest naming the target
organization, an immutable 40-hex contract commit, neutral `CI_*` variables, secret
environment-variable sources, exact GitHub App installations, and generated caller
outputs. It supports `check`, `dry-run`, and `apply` modes.

Variables are compared before mutation. Secrets are accepted only through explicitly
named environment variables, are masked before use, are never printed or persisted,
and are uploaded on every apply because GitHub exposes metadata but not values. A
redacted receipt records only names and outcomes. Dry-run performs no mutation and
never requires secret values; check requires secret names to exist but cannot claim
their opaque values are current.

App entries bind an exact slug, numeric App and installation IDs, all-repository selection,
permission map, and event list. The bootstrap reads the organization's installation
inventory and fails on any mismatch, suspension, inaccessible inventory, or permission
widening. It does not rename, recreate, install, or modify an App. Instead it emits the
exact expected configuration for the owner-mediated registration/install step. Private
keys remain explicit secret inputs. This manual boundary is mandatory until GitHub
offers an authenticated, replay-safe App-registration and key-rotation API.

Generated callers are produced only by an allowlisted canonical generator in the
checked-out contract repository. The manifest supplies the output path and arguments;
the bootstrap injects the single immutable contract SHA and refuses mutable refs,
absolute/traversal paths, unknown generators, duplicate outputs, or generated drift in
check mode. Apply replaces only declared generated outputs after every preflight and
generation succeeds, so partial generation cannot leave a mixed pin.

The target organization must equal the authenticated account's explicitly selected
organization. Foreign organizations, malformed identifiers, missing credentials,
unreadable configuration, partial API responses, and any failed mutation stop the run.
The receipt reports partial convergence honestly and never marks the run complete after
an error.

## Consequences

- Rerunning apply converges readable settings and safely re-uploads opaque secrets.
- Selected-repository installations are rejected because exact membership requires a
  separate repository allowlist and paginated inventory contract.
- App creation, installation, ruleset bypass assignment, and private-key generation
  remain visible owner actions rather than simulated automation.
- An App permission or event mismatch is a blocker; the script never broadens it.
- Caller generation is reproducible at one immutable trust root and cannot be
  approximated by handwritten YAML.
- Rollback uses the prior manifest/contract pin. Secret rollback requires the operator
  to supply the prior value because GitHub cannot return it.

## Verification

Adversarial tests use a fake `gh` boundary and disposable repositories to prove
idempotency, dry-run no-write behavior, exact organization/App scope, permission and
event equality, secret redaction, malformed and missing inputs, mutation failure
receipts, traversal rejection, generator allowlisting, and atomic same-SHA output.
