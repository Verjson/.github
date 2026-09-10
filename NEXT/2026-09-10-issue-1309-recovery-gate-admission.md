---
date: 2026-09-10
issue: 1309
impact: patch
title: Carry verified zero-provider recovery into gate admission
---

Reverify the immutable zero-provider proof at gate admission before accepting its exact retained failed authorization. Preserve pending-only ordinary admission and refusal after any provider boundary. Skip replay cleanup when trusted helper setup never succeeded, without masking missing helpers after setup.
