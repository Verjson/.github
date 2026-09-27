---
date: 2026-09-27
id: 20260927T025500Z
impact: patch
title: gate-rearm pins a ref-reachable validator and grants it the AI-review key
---
`gate-rearm.yml` calls `app-key-environment.yml@ebe23fa…` (a `main` commit; the previous `f56af66…` pin was a squashed branch head on no ref, and organization ruleset 20722935 rotated to it produced required-workflow runs with zero jobs) and passes the narrow named grant `AI_REVIEW_APP_PRIVATE_KEY` on that edge, because the validator's environment-bound job is key-bearing since e7db320 and the organization copy that masked the missing grant is withdrawn (#1385). ADR 0171 carries the dated amendment; rotate ruleset 20722935 to this commit.
