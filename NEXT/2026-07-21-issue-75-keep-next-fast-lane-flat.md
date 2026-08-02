---
date: 2026-07-21
issue: 75
title: Keep the NEXT fast lane limited to flat fragments
---

Tighten the merge gate's documentation allowlist so only flat `NEXT/*.md` files
qualify for no-model review. Nested paths under `NEXT/` now follow the normal AI
review lane, matching the fragment layout documented by the repository. Closes
#75; amends ADR 0007.
