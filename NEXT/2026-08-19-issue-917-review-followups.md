---
date: 2026-08-19
issue: 917
refs: 918, 924
title: Address AI-review follow-ups on the pnpm mock registry and publish-failure message
---

Three non-blocking AI-review findings from PR #916 and PR #923, fixed rather than left open. The pnpm loopback mock registry no longer computes a fragile semver-like sort for a package's `dist-tags.latest` (a mixed digit/non-digit prerelease segment such as `1.0.0-beta.1` could raise `TypeError`); any locked version is picked instead, since `--frozen-lockfile` never consults it. The per-scope npmrc override that routes a scope to the mock registry is now bounded to `APPROVED_INTERNAL_SCOPES` — the same allowlist already used to approve individual packages — instead of any scope discovered in the lockfile, so it can never reroute a scope the workflow hasn't already declared fully internal. And `node-release.yml`'s publish-failure message now distinguishes a registry-confirmed-missing version (`npm error code E404`) from a registry check that simply couldn't be confirmed (auth/network/other error) — the safe re-dispatch remedy is unchanged either way, but the message no longer overclaims what the registry actually said.
