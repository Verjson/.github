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
`client-id`. The workflow rejects an empty or numeric legacy ID and accepts the
GitHub `Iv...` client-ID form without imposing an undocumented fixed length.
The checkout persists only that minted token for the final atomic
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

No permanent canary-only workflow is added. Proving the material property means
atomically advancing the exact protected default branch and creating an exact
tag as this App. A supposedly disposable canary must then mutate the protected
branch again and delete a tag, testing extra authorization and leaving audit
history; a feature-branch or temporary-repository test would not exercise the
exact ruleset. The first canonical production release at the new contract pin is
therefore the live canary, and its run URL, snapshot commit, and tag are the
required receipt before treating the operational migration as proven.

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
- Closing the repository work does not by itself prove live authorization. The
  first production release receipt is the operational evidence boundary.

## Rollback

Revert the implementing pull request and repin consumers. That restores the
temporary `ORG_ADMIN_TOKEN` contract and its broad authority; it is an emergency
compatibility rollback, not the preferred steady state. Removing the App from
the ruleset bypass list or rotating its key immediately stops future App-backed
releases without rewriting released history.
