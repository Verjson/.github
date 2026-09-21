# 0198 — Confine runner host-evidence credentials to the protected deployment environment

- **Date:** 2026-09-21
- **Status:** Accepted
- **Issue:** [#1451](https://github.com/Verjson/.github/issues/1451)

## Context

The controller now uses the supported `@verjson/cli-cloud@1.0.0`
`runner-host-evidence` API for baseline, capacity, and post-update observations.
The API needs an SSH private key, a DigitalOcean read-only context, pinned
known-host data, and a GitHub token with organization self-hosted-runner read
authority. The existing DigitalOcean fleet token and runner-control token have
write authority and are not host-observation credentials.

The reusable deployment workflow runs collection and mutation in its trusted
parent process. GitHub Actions gives a job one environment boundary, so these
controller operations use the existing `production` environment, which already
gates the mutation path. A mutation-free dry run also reads the same host facts
and must cross that protected boundary before the runner credentials are
available. Caller workflows must not receive or forward private keys.

## Decision

- Use a dedicated GitHub App installation for host export. Its exact permissions
  are `metadata: read`, `contents: read`, `attestations: read`, and
  `organization_self_hosted_runners: read`. Configuration supplies reviewed App
  and installation IDs; a generated value is never treated as production
  authority.
- Store `RUNNER_HOST_EVIDENCE_APP_PRIVATE_KEY`,
  `RUNNER_HOST_EVIDENCE_SSH_PRIVATE_KEY`,
  `RUNNER_HOST_EVIDENCE_DOCTL_CONFIG`, and
  `RUNNER_HOST_EVIDENCE_KNOWN_HOSTS` only in the protected `production`
  environment. The two host credentials must be read-only, and the known-hosts
  value must contain operator-verified pins. Do not copy these values into
  organization or repository secrets or pass them through a caller workflow.
- Bind both dry-run and deployment jobs to `production`. Map the host-export
  secrets only onto controller collection and execution steps. The transport
  mints a short-lived App JWT internally, validates the exact installation and
  permission set, and narrows its installation token to the reviewed release
  repository. The JWT and App private key never enter a request or child
  environment.
- The transport gives the CLI only the read-only GitHub installation token and
  routes the SSH key by a mode-0600 temporary file path. It writes the
  DigitalOcean config and known-host pins beneath an isolated temporary home,
  rejects credential material echoed in CLI output, and removes these files
  after use. Missing or incomplete authority fails closed before a receipt is
  written. Host observation never falls back to
  `DIGITALOCEAN_RUNNER_FLEET_TOKEN` or `GH_RUNNER_CONTROL_TOKEN`.

## Consequences

The code path is testable without host credentials, but no live host evidence is
claimed until operators provision the dedicated App identity and protected
environment secrets, update the reviewed deployment configuration with actual
IDs and host selectors, and verify the host pins. This ADR does not provision
those values or assert that production has them. The existing production
environment binding is a sensitive workflow surface; any later move to a
separate host-observation environment must preserve the same parent-owned
credential boundary and synchronous evidence binding.
