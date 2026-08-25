---
date: 2026-08-25
issue: 1067
impact: minor
title: Authorize exact pre-contract snapshot reclassification from the base branch
---

Allow a reviewed base-branch permit to authorize one digest-bound, byte-identical move of an untagged pre-contract snapshot outside the active changelog namespaces without weakening ordinary immutable release history.

ADR 0132 defines the persistent permit, two-PR authorization sequence, tag guard, and fail-closed content and path bindings needed by Verjson/agents#13.
