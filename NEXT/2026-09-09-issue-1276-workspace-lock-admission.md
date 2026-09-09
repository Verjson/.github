---
date: 2026-09-09
issue: 1276
impact: patch
title: Admit verified checkout-local npm links in secretless manifests
---

Restore nested examples that link an internal package from the same checkout,
including file references to the workspace root, and allow empty private-package
approval sets when no private registry download exists. Verify local target
containment and package identity before excluding source records from acquisition;
retain exact registry URL, integrity and per-manifest authorization checks.
Regenerate the protected Node workflow and cover link escapes, substitutions and
empty-approval denial in the registered behavioral suite.
