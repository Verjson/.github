---
date: 2026-08-14
issue: 801
title: Require reviewed repository-specific privileged-merge check policies
---

Generate each adopter's exact required-check, GitHub App, workflow ID, and workflow path policy into its reviewed privileged-merge callers instead of reading a non-portable Actions variable; fail adoption and terminal promotion closed on stale identities while retaining event-driven deferral for checks that are genuinely pending.

The canonical direct path now carries the same explicit policy. Fleet conformance and
runtime tests cover missing, renamed, deleted, wrong-App, and wrong-workflow checks;
[ADR 0081](../docs/decisions/0081-event-driven-terminal-ai-promotion/README.md) and the
[adoption runbook](../docs/privileged-merge-adoption.md) document the boundary.

Independent security review additionally bound both generated caller byte streams and
their retry names to one immutable policy, preserved native context/App multiplicity,
bounded paginated conformance evidence, and tied each runtime check suite and job URL
to the exact trusted Actions run it claims.
