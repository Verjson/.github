---
date: 2026-09-27
issue: 1648
impact: patch
title: Bind the authorization check by its stored page, not the arm-run details_url
---
Since ADR 0203 the arm creates `AI review authorization` with the Actions token, and GitHub replaces the `details_url` of an Actions-owned check with the check's own `/runs/<id>` page. Every predicate that bound the check to the arm run through that field failed, so every review dispatched after #1569 merged (2026-09-27 02:02 UTC; first failure 02:07 UTC) stopped at preflight with `authorization check is not receipt-bound`. `verify-arm-receipt.sh`, both re-verification steps in `ai-review-merge.yml`, orphan recovery and re-promotion in `gate-rearm.yml`, and `ai-promotion-retry.yml` now bind the check to its stored page and take the arm run from `external_id`; the receipt keeps the arm-run URL. Live only after ruleset 20722935 rotates to the merge commit and adopters repin through the next contract release (ADR 0203 amendment).
