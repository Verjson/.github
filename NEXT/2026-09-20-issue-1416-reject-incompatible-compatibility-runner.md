---
date: 2026-09-20
issue: 1416
title: Reject incompatible secretless compatibility runner routing
impact: patch
---

Reject secretless trusted-ref compatibility runs when the selected runner is self-hosted, before dependency acquisition begins. Secretless pull-request runs remain on their untrusted runner and ignore the caller's runner input. Refresh the generated pre-ADR-0178 counterexample so its only difference remains the deferred job and the conformance test covers the new shared eligibility guard.
