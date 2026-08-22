---
date: 2026-08-22
issue: 933
impact: minor
title: Detect generated-caller pins that predate an assumed capability
---

Adds `config/capability-floors.json` and `scripts/capability-floor-audit.py`
(ADR 0114): given a capability's introducing commit and a snapshot of
consumer generated-caller pins, reports which pins are stale — not a git
ancestor of the commit that introduced a capability their generator needs —
using local `git merge-base --is-ancestor` against this repo's own history.
Seeded with the two real capabilities from issue #933's incident thread
(deepseek review-provider support, and the changelog contract's Renovate
default-source-link acceptance).

This is the local staleness computation only (Stage A of the ADR). Live
cross-repository pin discovery (Stage B — a scheduled workflow reading each
known consumer's generated caller via the GitHub API) is deliberately
out of scope here and left as explicit follow-up on issue #933, per the
ADR's rollout section, since it needs its own credential-scoping and
publication design rather than being folded into this first, purely local
increment.
