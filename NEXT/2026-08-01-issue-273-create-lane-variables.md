---
date: 2026-08-01
issue: 273
title: Create the VERJSON_LANE_* organization variables
---

Leg 1 of the lane rollout. The four lane variables defined by
[ADR 0040](../docs/decisions/0040-runner-lanes-and-admission-axes/README.md) now exist at
organization scope, all pointing at the current pool:

```
VERJSON_LANE_TRUSTED    = ["self-hosted","general"]
VERJSON_LANE_PRIVILEGED = ["self-hosted","general"]
VERJSON_LANE_UNTRUSTED  = ["self-hosted","general"]
VERJSON_LANE_FALLBACK   = ["self-hosted","general"]
```

**This leg is inert.** No workflow reads a `VERJSON_LANE_*` variable until Leg 2, and
`VERJSON_RUNNER_*` is untouched — removing it mid-rollout would break runs already in
flight. It stays until Leg 4 completes.

`UNTRUSTED` points at self-hosted rather than hosted. Hosted is free and unmetered for
public repositories, but a private repository on hosted rides the spending limit ADR 0040
measures, and past it jobs fail fast with an empty runner name. A lane variable is
organization-wide and cannot differ by repository visibility — that decoupling is the
point — so the value is chosen for the case that can fail.

`FALLBACK` is likewise self-hosted, and for the same reason. It fires only when a lane
variable is missing, which means something is already misconfigured; sending that case to
a pool that can refuse work is exactly the "terminal literal as safety net" trap ADR 0040
identifies. It is **our** default, switchable to hosted or another provider by editing the
variable, and distinct from GitHub's default runner group
([ADR 0041](../docs/decisions/0041-shared-admission-hosted-and-self-hosted/README.md)).
