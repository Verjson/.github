# 0207 — Withhold issue mutation from the terminal merge App

- **Date:** 2026-09-23
- **Status:** Accepted
- **Issue:** [Verjson/.github#1424](https://github.com/Verjson/.github/issues/1424)
- **Extends:** [ADR 0120](../0120-bind-terminal-merge-to-repository-app-token/README.md), [ADR 0131](../0131-bind-terminal-caller-read-ceiling-to-callee/README.md), [ADR 0138](../0138-keep-canonical-app-identities-organization-neutral/README.md)
- **Category:** merge authorization, GitHub App permission boundary

## Context

GitHub does not apply closing keywords when `merge-authorization` performs the
terminal merge, so issue state can remain stale without any failed API call or
workflow diagnostic. The App's live permission projection contains
`contents:write`, `metadata:read`, and `pull_requests:write`; it has no event
subscriptions and no `issues` permission.

The terminal token has one purpose. The canonical workflow mints it for one
validated repository and passes it only to `terminal-merge.sh`, whose mutation
is `gh pr merge --admin --squash --match-head-commit`. GitHub documents pull
request merge as requiring Pull requests write. Issue comments and labels that
target pull requests already accept Pull requests write as an alternative to
Issues write, while Checks is a separate permission. Giving this all-repository
installation Issues write would therefore add standalone issue mutation
authority without serving the terminal operation. It would also rely on an
implicit closing-keyword side effect that the merge API does not report.

## Decision

Withhold `issues:write` from App ID `4693283` and installation `155977749`.
Keep the exact App and installation ceiling at Contents write, Metadata read,
and Pull requests write, with no subscribed events. The App token remains
terminal-only and must never be used to inspect, comment on, label, close, or
otherwise mutate an issue.

Make the missing side effect visible for caller-token-visible issues in the
exact caller repository under the caller-owned `GITHUB_TOKEN`, with the minimum
additional `issues:read` permission. Before minting the merge App token,
capture GitHub's paginated `closingIssuesReferences` for the exact open
pull-request head. Bind the target and every returned issue repository to both
the event's immutable repository database ID and its current `nameWithOwner`;
reject a missing, malformed, or mismatched identity. Persist both coordinates
in the ephemeral pre-merge snapshot. Treat every JSON identity integer as an
exact positive native integer: booleans, floats, strings, nulls, zero, and
negative values fail closed even when a language would otherwise compare them
as numerically equal. After a successful merge, re-read the same scoped
resolved set:

- no references and all-closed references complete normally with a step summary;
- every caller-token-visible, same-repository issue still open produces an
  explicit warning and summary entry naming its URL and the intentionally
  withheld permission, without mutating it;
- a pre-merge API or integrity failure blocks the merge;
- a post-merge API failure or changed resolved set fails the reporting step so
  missing evidence cannot look successful; receipt confirmation still runs;
- after GitHub confirms `MERGED` for the exact authorized head, the privileged
  job exports only the validated arm-receipt artifact ID and a success boolean;
  the export precedes reporting so a reporting-only failure preserves cleanup
  eligibility, while a failed merge confirmation cannot authorize deletion;
- a dedicated one-minute secret-free cleanup job receives `actions:write`
  only, uses the exact fixed `ubuntu-24.04` hosted selector, has no merge
  environment or App credential, and deletes that exact artifact after the
  merge has already committed. Generated callers grant `actions:write` at
  the reusable-workflow boundary, while the privileged merge job remains
  explicitly downscoped to `actions:read`.

GitHub also accepts cross-repository closing keywords, including keywords in
pull-request descriptions and commit messages. The repository-scoped
`GITHUB_TOKEN` cannot read a private issue in another repository. Reimplementing
GitHub's evolving keyword and resolution semantics with a local body/commit
parser would be brittle and still could not establish access to the referenced
issue. This fallback therefore does not claim cross-repository completeness.
An accessible cross-repository node fails closed before merge; a private
cross-repository reference GitHub does not disclose is outside this fallback's
authority and remains ordinary PM reconciliation work.

## Consequences

Autonomous merges may still leave referenced issues open, but every stale item
within the caller-token-visible, same-repository scope is visible in the run
that created it. A PM reconciles private cross-repository references and any
reported same-repository issues under its ordinary authorization, without
turning the merge identity into a general issue-management principal. Any
future request to add Issues write is a new sensitive permission decision and
must replace this ADR with evidence of an operation that cannot be performed by
the caller-owned read-only path.

## Reviewed provisioning receipt

This secret-free receipt records metadata presence only. It contains no private
key, token, client secret, key fingerprint, or derived key material.

```json
{
  "schema": "verjson-merge-permission-decision-receipt/v1",
  "reviewedAt": "2026-09-23T19:03:44Z",
  "reviewer": {
    "login": "pyousefi",
    "userId": 1360670,
    "nodeId": "MDQ6VXNlcjEzNjA2NzA=",
    "organization": "Verjson",
    "organizationId": 279365001,
    "organizationNodeId": "O_kgDOEKbFiQ",
    "membershipRole": "admin",
    "membershipState": "active"
  },
  "decision": {
    "issuesWrite": "withheld",
    "reason": "terminal merge requires no standalone issue mutation; caller-token-visible same-repository reporting plus ordinary PM reconciliation is narrower"
  },
  "app": {
    "slug": "merge-authorization",
    "appId": 4693283,
    "nodeId": "A_kwHOEKbFic4AR50j",
    "clientId": "Iv23li18TKEWZbxcRgJD",
    "owner": {
      "login": "Verjson",
      "accountId": 279365001,
      "nodeId": "O_kgDOEKbFiQ"
    },
    "permissions": {
      "contents": "write",
      "metadata": "read",
      "pull_requests": "write"
    },
    "events": []
  },
  "installation": {
    "installationId": 155977749,
    "account": {
      "login": "Verjson",
      "accountId": 279365001,
      "nodeId": "O_kgDOEKbFiQ"
    },
    "repositorySelection": "all",
    "permissions": {
      "contents": "write",
      "metadata": "read",
      "pull_requests": "write"
    },
    "events": [],
    "suspendedAt": null,
    "updatedAt": "2026-09-14T09:24:48.000Z"
  },
  "tokenRequest": {
    "workflow": ".github/workflows/ai-privileged-merge.yml",
    "permissions": {
      "contents": "write",
      "pull_requests": "write"
    },
    "soleConsumer": "Merge the authorized head",
    "operation": "scripts/ci-gate/terminal-merge.sh"
  },
  "closingIssueFallback": {
    "authority": "caller repository GITHUB_TOKEN with issues:read",
    "repositoryBinding": "exact GITHUB_REPOSITORY_ID database ID plus github.repository nameWithOwner",
    "covered": "caller-token-visible same-repository closingIssuesReferences",
    "visibleCrossRepositoryPolicy": "fail closed before merge",
    "inaccessiblePrivateCrossRepositoryPolicy": "outside fallback authority; ordinary PM reconciliation",
    "localKeywordParser": "withheld because GitHub resolves both pull-request descriptions and commit messages under vendor-owned semantics"
  },
  "cleanupAuthority": {
    "callerBoundary": {
      "actions": "write",
      "reason": "reusable workflows cannot elevate the caller token"
    },
    "privilegedMergeJob": {
      "actions": "read",
      "environment": "merge-app"
    },
    "cleanupJob": {
      "name": "cleanup_arm_receipt",
      "runsOn": "ubuntu-24.04",
      "timeoutMinutes": 1,
      "selectorPolicy": "exact fixed hosted provenance; secret-free and environment-free",
      "permissions": {
        "actions": "write"
      },
      "environment": null,
      "secrets": [],
      "artifactIdSource": "needs.privileged_merge.outputs.arm_receipt_artifact_id",
      "successSource": "needs.privileged_merge.outputs.terminal_merge_succeeded",
      "confirmationSource": "steps.confirm-terminal-merge.outcome == 'success'",
      "failurePolicy": "sanitized visible warning; non-fatal to completed merge"
    }
  },
  "configuration": {
    "organization": {
      "login": "Verjson",
      "organizationId": 279365001,
      "nodeId": "O_kgDOEKbFiQ"
    },
    "clientIdVariable": {
      "name": "MERGE_APP_CLIENT_ID",
      "scope": "organization",
      "visibility": "all",
      "present": true,
      "updatedAt": "2026-08-23T16:39:44Z"
    },
    "environmentSecret": {
      "repository": "Verjson/.github",
      "repositoryId": 1269388380,
      "repositoryNodeId": "R_kgDOS6lUXA",
      "environment": "merge-app",
      "environmentId": 21611793391,
      "environmentNodeId": "EN_kwDOS6lUXM8AAAAFCCnL7w",
      "name": "MERGE_APP_PRIVATE_KEY",
      "present": true,
      "updatedAt": "2026-09-10T02:34:06Z",
      "deploymentBranchPolicy": {
        "customBranchPolicies": true,
        "protectedBranches": false,
        "branches": [
          {
            "id": 59568383,
            "name": "main",
            "type": "branch"
          }
        ]
      }
    },
    "repositorySecret": {
      "repository": "Verjson/.github",
      "repositoryId": 1269388380,
      "repositoryNodeId": "R_kgDOS6lUXA",
      "name": "MERGE_APP_PRIVATE_KEY",
      "present": false
    },
    "organizationBroadCopyResidue": {
      "organization": "Verjson",
      "organizationId": 279365001,
      "organizationNodeId": "O_kgDOEKbFiQ",
      "name": "MERGE_APP_PRIVATE_KEY",
      "present": true,
      "visibility": "all",
      "updatedAt": "2026-08-23T16:40:02Z",
      "trackingIssue": "https://github.com/Verjson/.github/issues/1285"
    }
  },
  "source": {
    "reviewedBaseCommit": "46d5fed5824bd03c6febf85a7cc481c6c528deca",
    "implementationDigest": "sha256:515b9516102062f575b3f2214ad05a35cc759509eb68ffe57b1d82a24fe1d08a",
    "digestMethod": "sha256 of the sha256sum manifest in this order: .github/workflows/ai-privileged-merge.yml, .github/workflows/ai-promotion-retry.yml, scripts/gen-privileged-merge-caller.sh, scripts/ci-gate/closing-issue-visibility.py, scripts/ci-gate/closing-issue-visibility.test.py, scripts/ci-gate/terminal-merge-app-token.test.py, scripts/ci-gate/post-merge-cleanup.test.py, scripts/ci-gate/arm-receipt-artifact-deletion-redaction.test.sh, scripts/ci-gate/native-automerge.test.sh, scripts/ci-gate/privileged-merge-caller-contract.test.sh, scripts/ci-gate/runner-routing-policy.test.sh, scripts/ci-gate/require-secrets.test.sh, scripts/actions-ci-groups.tsv"
  },
  "apiEvidence": [
    "GET /user",
    "GET /orgs/Verjson",
    "GET /repos/Verjson/.github",
    "GET /apps/merge-authorization",
    "GET /orgs/Verjson/installations",
    "GET /orgs/Verjson/actions/variables/MERGE_APP_CLIENT_ID",
    "GET /repos/Verjson/.github/environments/merge-app",
    "GET /repos/Verjson/.github/environments/merge-app/deployment-branch-policies",
    "GET /repos/Verjson/.github/environments/merge-app/secrets/MERGE_APP_PRIVATE_KEY",
    "GET /repos/Verjson/.github/actions/secrets/MERGE_APP_PRIVATE_KEY (404 absent)",
    "GET /orgs/Verjson/actions/secrets/MERGE_APP_PRIVATE_KEY"
  ],
  "testEvidence": [
    "python3 scripts/ci-gate/closing-issue-visibility.test.py",
    "python3 scripts/ci-gate/terminal-merge-app-token.test.py",
    "hostile accessible cross-repository reference rejection",
    "strict tampered-receipt binding and duplicate semantic locator rejection",
    "wrong-head MERGED confirmation rejection without cleanup eligibility export",
    "runner-routing policy exact fixed-hosted cleanup provenance and secret-bearing selector mutation rejection",
    "live metadata-only same-repository capture against Verjson/.github#1569"
  ]
}
```

The receipt's implementation digest binds the source without attempting an
impossible self-reference to its own Git commit. After a pull request exists,
the reciprocal #1424 comment must link this ADR, that PR, its landing commit,
and the CI run containing the fallback test evidence.
