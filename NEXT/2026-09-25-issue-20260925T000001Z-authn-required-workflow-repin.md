---
date: 2026-09-25
id: 20260925T000001Z
title: Repin Authn required workflow after canonical tool-cache merge
impact: patch
---

Repin the generated Authn required workflow and its ruleset verifier to the
canonical protected Node workflow at merge commit
`fff8891797f316a46417e6689719b79bfeafe01f`. The consumer declaration remains
the only baseline selection surface; the organization workflow retains the
credential, authorization, fail-closed validation, registry-integrity, and
evidence-receipt boundaries.
