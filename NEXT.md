# AI review cost optimization

## Runner governance — reusable workflows — 2026-07-15

Goal: keep every Verjson repo off GitHub-hosted runners, standardised on the
GCP self-hosted pool (or `manish`), with GitHub-hosted reserved as last resort.

Done:

- Added a `GCP` label to the 8 GCE self-hosted runners (org Actions API).
- New reusable workflow `notify-umbrella.yml` in this repo. Runner defaults to
  `[self-hosted, GCP]`; callers invoke
  `Verjson/.github/.github/workflows/notify-umbrella.yml@main`. Replaces the
  copy-pasted `notify-umbrella.yml` in the 8 submodule leaf repos
  (`catalog-api/ui/infra/helm/docs` → `Verjson/catalog`;
  `viager-app/docs/infra` → `Verjson/viager`). `actionlint` clean.

Next actions (all pending owner go-ahead — org-wide CI blast radius):

1. Convert the 8 leaf repos' `notify-umbrella.yml` to thin callers of the
   reusable workflow (one PR per repo, merge on green).
2. Runner-group reorg: create a `GCP` group (visibility: all), move the 8 GCE
   runners + `meta` into it, rename `Default` → `GitHub` (last resort), keep
   `manish`. Add a `manish` label to the `hostinger` runner.
3. Migrate the remaining ~27 repos running real CI on `ubuntu-latest` onto
   `[self-hosted, GCP]` — heaviest are `scv-iac` (16 wf), `scv` (12),
   `scrm-api` (5). Fix `verjson-infra-template/ci.yml.tmpl` (seeds new repos).
4. Decide fate of env-labelled deploy workflows (`dev`/`test`/`stage`/`prod`)
   in `scrm-*`/`scv-k8s` — they target no runner in the org pool today.
5. Optional guardrail: org ruleset requiring a check that fails any PR
   reintroducing a GitHub-hosted `runs-on`.

## Handoff — 2026-07-14

Current state:

- The cost-optimization work is merged to remote `main` through
  `Verjson/.github#17` (`b3b0935`), including the self-authored-review fallback,
  $0.50 Sonnet cap, and root-`NEXT.md` docs lane.
- `Verjson/verjson-observability#24` was re-run through this gate after the
  repair, took the docs fast lane, and merged successfully.
- `actionlint`, Prettier, and Git whitespace checks passed for the gate changes.

Next actions:

1. Exercise the self-authored fallback on a non-docs, non-sensitive test PR and
   confirm the approved-verdict comment, successful `ai-review`, and admin merge.
2. Begin the CI telemetry implementation tracked in
   `verjson-observability/NEXT.md`: conventions, bounded metrics, one-shot OTLP
   export, and CI dashboard.
3. After production telemetry exists, use the planned 2–4 week sample to tune
   Sonnet routing and review budgets.

Do not touch:

- `.tokensave/` is untracked user data.
- The closed local branches `agent/fix-self-authored-ai-review` and
  `agent/add-observability-ci-telemetry-next` are historical; start new work
  from current `origin/main`.

This checklist tracks the July 2026 review of the organization-wide AI merge
gate. Baseline from 13 paid runs: **$2.327 total / $0.179 average**; Haiku
averaged $0.113 and Sonnet averaged $0.236.

## Completed in `optimize/ai-review-costs`

- [x] Consolidate major Renovate guidance into the mandatory merge gate.
- [x] Convert the separately required advisory workflow into a zero-cost
      compatibility shim, eliminating duplicate LLM utilization.
- [x] Reduce the maximum agent loop from 60 turns to 24.
- [x] Add hard per-run budgets: $0.15 for Haiku and $0.50 for Sonnet.
- [x] Prepare PR metadata and diff once rather than paying the model to fetch
      them repeatedly.
- [x] Use structured model output and deterministic shell review submission,
      removing the observed GitHub-tool permission denials.
- [x] Reduce checkout history from full history to two commits.
- [x] Add a 30-second synchronization debounce and verify the head SHA before
      invoking the model.
- [x] Add a deterministic documentation/community-health fast lane.
- [x] Include root `NEXT.md` planning documents in the deterministic docs lane.
- [x] Enforce the documented manifest/lockfile allowlist for non-major
      Renovate fast-lane changes.
- [x] Give major dependency updates targeted review instructions in their one
      mandatory model review.
- [x] Embed head SHA and model metadata in each submitted review for auditing.
- [x] Handle self-authored PRs: when the configured org-admin token cannot
      approve its own PR, leave an audited approved-verdict comment and let the
      required gate check plus admin merge job enforce the decision.
- [x] Validate both workflows with `actionlint`, Prettier, and Git whitespace
      checks.

## Follow-up after publishing the merged commit

- [x] Remove `.github/workflows/renovate-ai-review.yml` from organization
      ruleset `main-protection` (ID `18098028`) after the consolidated gate
      reached the remote default branch.
- [x] Delete the compatibility workflow after the ruleset change propagated.
- [ ] Collect two to four weeks of cost, turn, model, diff-size, verdict, and
      rerun data. The action already logs cost and turn totals; export them into a
      durable dashboard before changing routing based on anecdotal samples.
- [ ] Use the collected data to narrow Sonnet routing. In particular, evaluate
      routine `.github/` files and trusted action-version bumps separately from
      executable workflow or security-policy changes.
- [ ] Evaluate cached-head and incremental-diff reviews after telemetry exists.
      Retain full review for force-pushes and sensitive paths.

## Guardrails

- CI remains mandatory before every model invocation and merge.
- Sensitive changes continue to use Sonnet.
- Missing credentials, invalid structured output, budget exhaustion, red CI,
  and blocking findings all fail closed.
- Fast lanes remain deterministic and leave an auditable PR comment.
