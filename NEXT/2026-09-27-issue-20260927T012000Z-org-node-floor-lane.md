---
date: 2026-09-27
id: 20260927T012000Z
impact: minor
title: The conditional Node floor lane is live as organization ruleset 24056850 (#1274)
---
Organization ruleset 24056850 `core-checks-node-floor` requires `ci-node22 / build-test` and `ci-node22 / eligibility` on the default branch of every repository carrying `verjson-stack=node`, `verjson-core-checks=enforced`, and `verjson-node-floor=node22`, exactly as ADR 0176 declared and `scripts/node-floor-ruleset.py render` emits; its bypass actors are mirrored from `core-checks-node` and reviewed through `config/org-ruleset-conformance-policy.json`. `verjson-object-storage` is enrolled and its hand-built repository ruleset 22590648 is retired. ADR 0176 gains the dated rollout amendment with the failing and non-opted-in control receipts.
