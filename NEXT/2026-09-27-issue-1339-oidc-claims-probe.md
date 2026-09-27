---
date: 2026-09-27
issue: 1339
impact: patch
title: Temporary required-workflow probe records the OIDC identity shape a private consumer presents
---
`oidc-claims-probe-1339.yml` is a temporary workflow injected into the private scratch repository `Verjson/demo-repository` by a temporary organization required-workflow ruleset. It requests the job's OIDC token and prints only the decoded claims (token, header segments, and signature are masked; `jti`, `exp`, `iat`, `nbf` are removed) plus the run metadata GitHub reports, so the exact identity shape a required workflow presents inside a private consumer can be recorded for ADR 0077's residual risk. It is deleted in the follow-up once the capture is recorded.
