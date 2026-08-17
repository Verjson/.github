---
date: 2026-08-17
issue: 879
title: Support pnpm in secretless Node CI
impact: minor
---

Canonical secretless Node validation now supports pnpm lockfile version 9 through
an explicit package-manager input. It preserves exact private-package authorization,
integrity-bound cache transfer, credentialless frozen installation, and cleanup while
leaving existing npm callers unchanged. Scoped and unscoped peer-context keys share
one fail-closed identity grammar across acquisition authorization and lifecycle rebuilds.
