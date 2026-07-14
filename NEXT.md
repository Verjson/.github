# AI review cost optimization

This checklist tracks the July 2026 review of the organization-wide AI merge
gate. Baseline from 13 paid runs: **$2.327 total / $0.179 average**; Haiku
averaged $0.113 and Sonnet averaged $0.236.

## Completed in `optimize/ai-review-costs`

- [x] Consolidate major Renovate guidance into the mandatory merge gate.
- [x] Convert the separately required advisory workflow into a zero-cost
      compatibility shim, eliminating duplicate LLM utilization.
- [x] Reduce the maximum agent loop from 60 turns to 24.
- [x] Add hard per-run budgets: $0.15 for Haiku and $0.35 for Sonnet.
- [x] Prepare PR metadata and diff once rather than paying the model to fetch
      them repeatedly.
- [x] Use structured model output and deterministic shell review submission,
      removing the observed GitHub-tool permission denials.
- [x] Reduce checkout history from full history to two commits.
- [x] Add a 30-second synchronization debounce and verify the head SHA before
      invoking the model.
- [x] Add a deterministic documentation/community-health fast lane.
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
