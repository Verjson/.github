# Gate retries a third time on a transient structured-output flake — 2026-07-20

Fixes #64 (sensitive-class: org merge-gate behavior). The `ai-review` job could
fail with `error_max_structured_output_retries` — the model failing to emit its
structured verdict — on **both** the cheap first pass and the strong-tier
escalation in the same run, leaving the deterministic submit with no verdict and
failing closed (~50% of runs flaked on 2026-07-20). Added a **second bounded
escalation** (`claude_retry2`, sonnet-5, guarded on both prior passes being empty)
before the fail-closed submit; the verdict now falls back `claude_retry2 →
claude_retry → claude`. Because the flakes are roughly independent, a third attempt
clears the run ≈⅞ of the time. Fail-closed is preserved (`continue-on-error`; still
labels `ai-review-inconclusive` and refuses to merge if all three come back empty).
A mitigation, not a root-cause fix — #64 stays open to track distinguishing the
action's failure subtype if flakes persist. Pinned by
`scripts/ci-gate/ai-review-retry.test.sh` (mutation-tested, wired into
`actions-ci`). ADR 0015 (extends ADR 0002), carries the effective diff.
