---
date: 2026-09-12
id: 20260912T055348Z
impact: patch
title: Revalidate refreshed container deployment release evidence
---

The canonical container deployment workflow now validates refreshed manifest identity and deployed digest evidence against the immutable plan before advancing to the next host. Dishonest or stale second-host responses fail closed before mutation, while bounded replay and credential separation remain intact.
