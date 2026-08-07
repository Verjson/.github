---
date: 2026-08-07
issue: 537
title: Expose portable CI command entry points
---

Add standard Make targets for workflow linting, the documented behavioral smoke test, NEXT rendering, and ADR-index validation while keeping GitHub merge control-plane workflows and runner availability outside the portability boundary.

ADR 0067 records the engine-versus-availability split, rejects Earthly and Dagger for the repository's current shape, and sequences neutral environment mapping, `act` evaluation, and sensitive hosted-to-self-hosted overflow as separate follow-up work under #483.
