---
date: 2026-09-23
id: 20260923T000006Z
title: Harden declaration-only protected baseline execution
impact: patch
---

Protected consumers now execute the compatibility lane when the declaration is
the only baseline input, and explicit prerelease authorization is honored by
the bounded-range resolver. The generated adoption instructions document the
split ownership for subsequent `@verjson/*` packages.
