---
date: 2026-08-26
id: 20260826T010957Z
refs: 1088
impact: minor
title: Clarify v1 readiness enforcement
---

Clarify the organization v1 readiness contract so dependency matrices pass vacuously only when there is no in-wave sibling range to exercise, generated changelog pins are capability floors with live ruleset enforcement, published packages cannot pass without immutable snapshots, and npm publication remains explicit-dispatch only.

The contract now requires direct fragment inspection during the impact grace period, an explicit major v1 fragment, wrong-version and exact-v1 release-path controls, a safe exception for guarded non-npm tag namespaces, and adjudication of known dependency deprecation or end-of-support markers. Focused mutation tests keep each fail-closed distinction from drifting back into ambiguous prose.
