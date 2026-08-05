# .github
Public organization profile, visible to anyone

## Purpose

The organization's shared CI surface: the merge gate, the reusable
`workflow_call` workflows every Verjson repository builds on, the composite
actions they use, and the decision records that govern all of it. Changing
something here changes CI for the whole organization at once.

## Ownership

Owned by the verJSON platform team. Reach us by opening an issue in this
repository; anything touching the merge gate, runner topology, or a ruleset also
needs a decision record under [`docs/decisions/`](docs/decisions/).

## Local validation

Everything here is checked by shell tests wired into
[`actions-ci`](.github/workflows/actions-ci.yml). Run them the way CI does:

```bash
bash scripts/repo-hygiene.test.sh        # or any single scripts/**/*.test.sh
bash scripts/gen-adr-index.sh --check    # the ADR index is generated, not edited
python3 scripts/changelog.py validate --repo-root .
```

Add a `NEXT/` fragment in the same commit as any change to behaviour, pins,
docs, or config — see [`NEXT/README.md`](NEXT/README.md).

## Versioned actions and reusable workflows

The repository ships all `.github/actions/*` actions and
`.github/workflows/*` reusable workflows on one SemVer line. Pin the immutable
release when reproducibility matters:

```yaml
uses: Verjson/.github/.github/workflows/node-ci.yml@v2.2.0
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

## Generated-artifact checks: `generated-artifacts.yml`

Consumer repositories check their derived files — the ADR index, the canonical
changelog — through one shared workflow instead of a hand-written
`generated-docs` job. The shared workflow owns checkout, runner selection,
`contents: read`, the timeout and the failure report; the caller keeps its own
generators and generated content.

```yaml
name: generated artifacts

on:
  pull_request:

permissions:
  contents: read

jobs:
  generated-artifacts:
    uses: Verjson/.github/.github/workflows/generated-artifacts.yml@<contract-sha>
    with:
      adr-index: true
      changelog: true
      contract_ref: <contract-sha>
```

Checks are **enumerated opt-ins**, never a command: the workflow accepts no
shell, so a caller names a supported artifact and nothing else.

| Input | Type | Default | Meaning |
| --- | --- | --- | --- |
| `adr-index` | boolean | `false` | `scripts/gen-adr-index.sh --check` must report the committed `docs/decisions/README.md` current |
| `changelog` | boolean | `false` | The pinned contract's `changelog.py` must validate the unreleased `NEXT/` fragments, and on a pull request also `check-pr` |
| `contract_ref` | string | `''` | Immutable `Verjson/.github` commit carrying the changelog contract. Required when `changelog: true` |
| `legacy_dir` | string | `''` | Temporary former unreleased-fragment directory, passed through to the contract engine |
| `runner` | string | `''` | Optional JSON runner labels; Verjson callers default by visibility, callers outside `Verjson` get `ubuntu-24.04` |

At least one check must be enabled — a call that validates nothing fails rather
than reporting green. A requested check whose generator is absent is reported as
*unavailable* and fails, distinctly from a *stale* artifact, so nobody is sent to
re-run a script the repository does not have.

The called job ID is `validate`, so with the caller job ID above the check is
`generated artifacts / validate`.

`changelog: true` **replaces** the [`changelog-validate.yml`](.github/workflows/changelog-validate.yml)
caller rather than accompanying it: it runs that same pinned contract engine, so
a repository calling both parses every fragment twice for one verdict. A
repository that only needs changelog validation can keep its existing generated
caller unchanged.

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

### Hygiene is baseline CI, not evidence that anything works

[`repo-hygiene.yml`](.github/workflows/repo-hygiene.yml) checks that a repository
carries a root `README.md` answering purpose, ownership and local validation
([ADR 0046](docs/decisions/0046-baseline-repository-hygiene/README.md)). It is
**baseline** CI: a green hygiene check means a reader can orient themselves in the
repository, and says nothing whatever about whether the repository's code works.

The gate merges on green CI, so this distinction is load-bearing. Hygiene never
substitutes for a repository's own build, test, or config validation, and a
repository whose only check is hygiene has no CI — green there must not be read as
domain behaviour having been verified. It ships in audit mode by default; see
[`docs/repo-hygiene/`](docs/repo-hygiene/README.md) for adoption and exemptions.
