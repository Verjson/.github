# Renovate compatibility operations

The organization compatibility control plane consumes the immutable policy registry
from `Verjson/renovate-config`. It distinguishes evidence collection from policy
mutation: the current rollout reports candidates and runs secretless canaries, while a
human-reviewed policy pull request remains the only way to add or remove a hold.

## App permissions

Install a dedicated GitHub App and expose its ID as
`RENOVATE_COMPATIBILITY_APP_ID` and private key as
`RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY`. Grant read access to organization/repository
metadata, contents, pull requests, checks/statuses, and Actions runs/artifacts. Do not
grant contents, pull-request, issue, package, administration, deployment, or workflow
write access in observe-only mode.

The scheduled reconciler inventories failing Renovate pull requests and uploads a
14-day report. An entry marked `needs-controlled-retry` is evidence to investigate,
not authority to create a hold. Before proposing registry data, prove the base branch
green and reproduce the same normalized failure in one controlled retry. Prefer a
consumer adaptation whenever the supported dependency interface can be adopted.

## Candidate canaries

Generate a caller; do not author one by hand:

```sh
scripts/gen-renovate-compatibility-caller.sh \
  <immutable-Verjson-.github-SHA> typescript 7.1.0 node-jest-ts-jest \
  > .github/workflows/renovate-compatibility.yml
```

The reusable job runs candidate code without credentials on the untrusted lane. It
disables dependency lifecycle scripts and executes existing `build`, `typecheck`, and
`test` scripts when present. The receipt records the exact repository commit,
candidate, profile, caller ref/SHA, fixed command contract, and result. It is authored
by a separate credentialless control job on the isolated trusted lane, so candidate code cannot
rewrite the authoritative evidence. A green unrelated profile is not evidence to
remove another profile's hold.

Rollback is disabling the reconciler schedule or removing the generated consumer
caller. Neither action changes the registry or Renovate eligibility.
