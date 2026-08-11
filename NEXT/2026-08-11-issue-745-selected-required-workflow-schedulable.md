---
date: 2026-08-11
issue: 745
title: Fail the arm rollout audit while the selected required workflow cannot run
---

Verify that the workflow `main-protection` currently selects declares at least one
trigger a ruleset can fire — `pull_request`, `pull_request_target`, or `merge_group` —
and check it before any rollout precondition. `#642` removed the `pull_request` trigger
from the selected `ai-review-merge.yml` on 2026-08-08, which left the required-workflow
record unschedulable: every governed pull request showed "Workflow configuration
invalid" and produced no run, no check, and no receipt for four days. The audit
previously validated only the *replacement* workflow, and reported the unrelated
fleet-readiness gap first, so it never named the live outage.
