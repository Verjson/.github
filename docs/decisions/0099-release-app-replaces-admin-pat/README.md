# 0099 — A dedicated release App replaces the admin PAT

- **Date:** 2026-08-13
- **Issue:** [Verjson/.github#329](https://github.com/Verjson/.github/issues/329)
- **Related:** [Verjson/.github#762](https://github.com/Verjson/.github/issues/762)
- **Supersedes:** ADR 0052

## Context

ADR 0052 restored canonical releases by passing `ORG_ADMIN_TOKEN` to the one job
that atomically pushes an immutable snapshot commit and its exact tag. It proved
that Contents write is necessary but does not bypass `main-protection`. The PAT
worked because its administrator identity bypassed the ruleset, but its authority
was far wider and longer-lived than one repository release required.

The organization now has a dedicated `verjson-release-authorization` GitHub App.
Its repository permissions are only Contents read/write and implicit Metadata
read. It has no Pull requests, Actions, Administration, or organization
permission, and it is an always-bypass actor on the exact organization
`main-protection` ruleset. The organization variable `RELEASE_APP_CLIENT_ID`
contains its `Iv...` client ID; `RELEASE_APP_PRIVATE_KEY` contains its private
key.

The App installation and both organization credential values are available to
the Verjson repository fleet. The owner explicitly chose this convenience-first
scope so canonical packaging repositories do not need manual admission whenever
one is added. That choice changes the threat boundary: any compromised trusted
workflow able to read the organization-wide private key could request an
installation token for another repository on which the App is installed.

## Decision

The canonical reusable release workflow mints its own short-lived installation
token with the audited immutable
`actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1`
pin. Every mint supplies exactly:

- the App client ID and private key;
- `owner: ${{ github.repository_owner }}`;
- `repositories: ${{ github.event.repository.name }}`; and
- `permission-contents: write`.

The pinned action's v3 contract deprecates legacy `app-id` and recommends
`client-id`. The workflow rejects an empty or all-numeric legacy ID, then
delegates the full client-ID grammar to that pinned action. In particular, it
does not assume an undocumented length or character set; the action's own dotted
`Iv1.0123456789abcdef` fixture remains supported. The checkout persists only
that minted token for the final atomic
push. The reusable contract no longer accepts `push_token`, and generated
callers no longer receive `ORG_ADMIN_TOKEN`; they pass only
`RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY`.

Repository binding in the canonical workflow is a defense against accidental or
future generator drift, not a cryptographic limit on the organization-wide
private key. A separate trusted workflow holding that key could ask for a wider
token. Selected-repository App installation and secret visibility would remove
most of that exposure but reintroduce per-repository provisioning. A central
token broker that derives the repository from an authenticated workflow identity
could retain convenient adoption with a stronger boundary, at higher operational
complexity. Neither is adopted here.

A permanent manual canary proves the authorization boundary before a production
release. It has no user-controlled repository, ref, or version inputs, runs only
from the default-branch revision through the existing trusted organization lane
and `VERJSON_LANE_FALLBACK` contract, and fixes its remote target to the
otherwise-absent `develop` branch plus a run-unique SemVer
prerelease tag. Organization ruleset `main-protection` (ID `18098028`) explicitly
targets `develop`, so an atomic push there exercises the same ruleset and named
App bypass as the canonical default-branch push without mutating `main`.

The canary creates an isolated local history and fragment, then invokes the exact
checked-in `scripts/changelog.py release` path to produce the snapshot commit and
annotated tag. It records a successful push before verifying both remote refs,
retains the run URL, App slug and installation, commit, tag, ruleset and proof
boundary in the Actions step summary, and cleans up under `always()` only after
both refs still resolve exactly to this run's commit and tag object. Cleanup is
one atomic deletion and then proves both refs absent; a mismatch is preserved for
investigation instead of deleting someone else's ref.

This is strong live evidence for the exact organization ruleset and App bypass,
but it is not evidence about a rule scoped only to the default branch or the
default branch ref itself. The production release path retains its own
default-branch and immutable-snapshot guards.

## Consequences

- Release authorization is short-lived, repository-scoped at mint time, and
  limited to Contents write instead of an administrator PAT.
- The App's named ruleset bypass remains mandatory; Contents write alone still
  receives GH013.
- Organization-wide installation and credential availability make adoption
  automatic but preserve the trusted-workflow cross-repository risk described
  above.
- Consumers must regenerate both `release-node` and `contract-test` at the same
  immutable contract commit. Handwritten partial migration is unsupported.
- Closing the repository work does not by itself prove live authorization. A
  successful manual canary receipt is the operational evidence boundary for the
  shared ruleset and App bypass.

## Rollback

Revert the implementing pull request and repin consumers. That restores the
temporary `ORG_ADMIN_TOKEN` contract and its broad authority; it is an emergency
compatibility rollback, not the preferred steady state. Removing the App from
the ruleset bypass list or rotating its key immediately stops future App-backed
releases without rewriting released history.
