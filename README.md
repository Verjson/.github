# .github
Public organization profile, visible to anyone

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

- Reviews run **once per ready PR** (`opened` / `reopened` / `ready_for_review`),
  not on every push. Re-run by adding the `re-review` label (auto-consumed) or
  `gh workflow run ai-review-merge.yml --repo Verjson/.github -f pr_number=<N> -f repository=<owner/repo>`.
- Opt a PR out entirely with the `hold` label, a `DO NOT MERGE` title marker,
  or draft status — re-checked at merge time, so a late `hold` still stops the
  merge.
- Fail-closed: a missing secret, model error, red CI, or a request-changes
  review all leave the PR open; nothing merges silently.
