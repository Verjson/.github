# Main-only App key rollout

This is the operational completion record for [#1285](https://github.com/Verjson/.github/issues/1285)
and [ADR 0166](decisions/0166-environment-only-app-private-keys/README.md).
Contract delivery and exposure removal are separate milestones. This source change
does not create environments, copy/delete keys, edit rulesets or dispatch consumers.

| Role | Required reusable input | Caller-owned environment | Environment secret |
| --- | --- | --- | --- |
| Release | `release_environment` | `release-app` | `RELEASE_APP_PRIVATE_KEY` |
| Merge | `merge_environment` | `merge-app` | `MERGE_APP_PRIVATE_KEY` |
| AI review | `ai_review_environment` | `ai-review-app` | `AI_REVIEW_APP_PRIVATE_KEY` |

Keep public App client IDs in their existing variables. Model API credentials and
`NODE_AUTH_TOKEN` are outside this App-key migration; their explicit grants remain.
`node-release.yml` does not consume the release App key. Snapshot publication and
container release do, as does Renovate attribution.

## Stage the entire shared-pin cohort

Inventory every App-key reader and every repository selected by the relevant
organization secrets and inherited required workflows. Include generated release,
privileged merge/retry, review/rearm, Renovate attribution and canary callers.
Use authenticated metadata queries; a forbidden or incomplete inventory is unknown,
never proof of absence. Do not print or hash key values.

Authenticated inspection on 2026-09-10 found that the
`ai-authorization-arm-required` organization ruleset (ID `20722935`) selects
`.github/workflows/gate-rearm.yml` from repository `1269388380` at
`refs/heads/main` **without a `sha` field**. Its observed `updated_at` was
`2026-08-26T02:04:11.250Z`. This is a live branch binding, not an existing immutable
pin: merging this contract would otherwise change every selected consumer at once.

Before merging this contract, freeze that workflow entry to merged commit
`c597d6908e3aa38d9a041c2150afadcbff32cf6d`. That protected revision retains the
existing broad/forwarded review-key contract and the #1275 body-edit admission
guard. Verify that the live protected-main workflow still has those same bytes,
then add only the workflow entry's `sha`. Preserve its path/ref/repository identity,
active enforcement, bypass actors, creation policy and all selectors, including
the default-branch/develop targets and repository-property cohort.

Retain the complete preimage, reviewed candidate and verified postimage, their
timestamps, the selected cohort, and the exact one-field diff on #1285. Immediately
re-read the full preimage before PUT and reject drift. An uncertain response or
unexpected postimage requires inspection, not automatic overwrite or rollback.
The protective freeze is complete only when its live receipt is recorded; these
instructions do not claim it has been applied. It preserves current behavior and
does not activate the environment-key contract or remove any broad key.

Do not move this protective pin to the new contract for one prepared repository,
or remove the broad AI key while any inherited required workflow still needs it.

For every affected repository, prepare the three role environments with:

```json
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
```

Each environment's deployment-branch policy collection must contain exactly:

```json
{"name":"main","type":"branch"}
```

Remove obsolete wildcard, tag and other branch rules through the owner-reviewed
rollout. Reviewers/timers may add approval delay but cannot replace the exact branch
restriction. Confirm the repository default branch is `main`. Store each private
key directly in its environment with a secure local file/stdin operation, for example:

```sh
gh secret set RELEASE_APP_PRIVATE_KEY --repo OWNER/REPO --env release-app < /secure/path/release.pem
```

Use the corresponding environment/key for merge and review. Keys never belong in
issues, chat, artifacts, logs, PR bodies or workflow inputs. Provisioning alongside
existing broad copies is a temporary migration state and remains exposed.

## Activate and remove broad copies

After all repositories in the shared required-workflow cohort are provisioned,
regenerate each caller from the same reviewed immutable contract SHA. Keep complete
changelog caller/renderer/test/release artifacts together and exercise the pinned
release command in a disposable checkout. Confirm each generated caller selects
the role name, has no App-key secret mapping and has no `secrets: inherit` grant.

Coordinate advancement of the protective `gate-rearm.yml` pin to the new reviewed
contract with those consumer PRs, after the entire selected cohort is provisioned.
Verify exact-main execution and the native environment deployment records for every
key role. An uncredentialed policy prerequisite must fail if environment metadata
cannot be read with the job token. Do not add a broad App/token just to make that
check green. The workflow cannot prove that a populated key came from the
environment while broad copies remain.

Only after all old readers are retired, delete the organization and repository
copies of the three App private keys through the authorized operator rollout.
Record the affected cohort, policy and contract SHAs, successful canary runs and
metadata-only deletion receipts. Run:

```sh
python3 scripts/app-key-environment-audit.py --repo OWNER/REPO
```

The audit uses `gh` with operator permission to list organization, repository and
environment secret metadata. It is read-only and returns exit 1 for unreadable or
inconsistent inventory, missing environment keys, broad copies or policy drift.
An organization-wide broad copy fails the audit even if it is currently scoped
away from this repository; this prevents calling a partial migration complete.
The ordinary job token need not and should not gain that metadata authority.

Finally, repeat the non-main branch proof with a harmless workflow that omits
`environment` and reports only whether each key is populated. All three must be
absent. A separate non-main job requesting a role environment must be denied by
GitHub before it starts. Clean up proof branches after retaining the nonsecret
run URLs and results. Do not declare #1285 exposure removed until every affected
repository has both successful main consumption and these denial receipts.

Rollback pauses dispatch and restores a reviewed environment/pin configuration
within the same isolated storage model. It never restores an organization or
repository App private key to regain compatibility.

## Canonical repository self-adoption gate

The canonical repository itself runs native main entrypoints. Before merging this contract, provision and verify its three role environments and their keys; a consumer repin is not required to trigger this self-adoption. Initial read-only GitHub API inventory on 2026-09-10 found only `runner-fleet-production`. The operator subsequently prepared all three exact main-only policies, but had not provisioned their environment keys; key provisioning remains a merge prerequisite. The new admission deliberately fails when an environment is missing or incorrectly configured, including the historically advisory arm workflow. Prepare and verify the complete shared-pin cohort before cutover.
