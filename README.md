# .github
Public organization profile, visible to anyone

## Versioned actions and reusable workflows

The repository ships all `.github/actions/*` actions and
`.github/workflows/*` reusable workflows on one SemVer line. Pin the immutable
release when reproducibility matters:

```yaml
uses: Verjson/.github/.github/workflows/node-ci.yml@v2.1.0
```

`@v2` is the moving major alias: it receives every compatible v2 release without
a caller edit, but is intentionally mutable. See the
[versioning and release guide](docs/reusable-workflow-versioning.md) for the
trade-off and release process.

## Reusable actionlint

Consumer repositories can lint their workflow files with the same pinned,
checksum-verified actionlint used here:

```yaml
name: actionlint

on:
  pull_request:
    paths:
      - '.github/workflows/**'
      - '.github/actionlint.yaml'

permissions:
  contents: read

jobs:
  actionlint:
    uses: Verjson/.github/.github/workflows/actionlint.yml@bfecdd0111582d0ddada558e6b4d0cadd9b488bd
```

Callers outside `Verjson` use `ubuntu-24.04` by default. Verjson callers
temporarily use `[self-hosted, general]`; `github-hosted-runner: true` is an
explicit compatibility escape hatch, not the organization default.

The caller owns all triggers and path filters; `workflow_call` never runs on its
own. Keep the caller unfiltered when actionlint is a required check. If the
caller uses `paths:` as above, do not require the check for changes outside
those paths: GitHub creates no check run for an unmatched workflow, so a required
check would remain pending.

The called job ID is `actionlint`. With the caller job ID above, the resulting
check is `actionlint / actionlint`; select the check emitted by a completed run
when configuring a ruleset. Renaming either job changes the required-check
context. The caller must grant `contents: read`, because a reusable workflow
cannot elevate the caller's `GITHUB_TOKEN`.

## Org-wide merge gate: `ai-review-merge.yml`

Every Verjson repo's PRs pass through
[`.github/workflows/ai-review-merge.yml`](.github/workflows/ai-review-merge.yml),
required on all repos via the `main-protection` org ruleset (governance record:
viager-docs ADR-018 and its amendments). It reviews each PR and, on pass +
green CI, squash-merges it with the org-admin ruleset bypass.

### Cost lanes (deterministic first, AI only where it earns its keep)

| Lane | Who qualifies | Verified by |
| --- | --- | --- |
| **fast** | Submodule pointer bumps | Script: every changed file is a gitlink hunk and each new SHA is on the submodule's default branch (GitHub compare API) |
| **fast** | Renovate non-major updates | Script: bot-authored commits only, manifest/lockfile-only diff, `update/<patch\|minor\|pin\|digest\|lockFileMaintenance>` label (stamped by the shared [renovate-config](https://github.com/Verjson/renovate-config) preset) |
| **fast** | Deletions-only PRs | Script: every file status is `removed`; CI must still pass |
| **ai** | Everything else | Claude review, run **only after the rest of CI is green** (red PRs never invoke the model). Routine paths → Haiku; sensitive paths (authz/ABAC, payments/ledger, webhooks, secrets, workflows) → Sonnet. Turn-capped. |

Fast-lane merges leave a written audit comment on the PR stating the verified
reason; AI-lane merges leave a review.

### Triggers and human controls

- Reviews run on every ready-PR revision (`opened` / `reopened` /
  `ready_for_review` / `synchronize`), so a Renovate rebase re-fires the gate and
  the required check stays fresh on the new head. Cost stays bounded: fast-lane
  synchronizes invoke no model, and the AI lane only runs after CI is green.
  Force a re-run with the `re-review` label (auto-consumed) or
  `gh workflow run ai-review-merge.yml --repo <owner/repo> -f pr_number=<N>`.
  Dispatch in the repository that owns the PR; sibling targets are intentionally
  unsupported by the repository-scoped validation token. A successful manual gate
  automatically dispatches the trusted merge continuation for the reviewed head.
- Opt a PR out entirely with the `hold` label, a `DO NOT MERGE` title marker,
  or draft status — re-checked at merge time, so a late `hold` still stops the
  merge.
- Fail-closed: a missing secret, model error, red CI, or a request-changes
  review all leave the PR open; nothing merges silently.
