---
date: 2026-09-12
id: 20260912T033225Z
impact: patch
title: Harden deployment transport and pre-mutation runner admission
---

The canonical deployment controller now validates online, idle, admitted runners against the reviewed group, labels, and tools before retaining admission or mutating any host. Workload evidence and probe children receive a minimal allowlist without `HOME`, `SSH_AUTH_SOCK`, deployment CLI locators, or deployment credentials; the mutating CLI retains separate explicit provider and runner-control environment. The GitHub canary broker now requires a bounded paginated run inventory whose trusted `total_count` matches every record before replay detection or dispatch polling. Regenerate and repin the complete generated deployment artifact set, including controller, transport, and contract test, to a single merge commit. Implements existing ADR 0078/0144 boundaries for #1281 and #629; no new architectural decision is introduced.
