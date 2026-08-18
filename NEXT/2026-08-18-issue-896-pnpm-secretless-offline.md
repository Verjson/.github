---
date: 2026-08-18
issue: 896
title: Serve verified private pnpm packages from a loopback mock registry
---

Rewriting a pnpm lock's private tarball URLs to local `file:` paths kept the resolution registry-shaped in name only: pnpm's own supply-chain policy rejects a `name@version` dependency path backed by a non-registry resolution (`ERR_PNPM_RESOLUTION_SHAPE_MISMATCH`), which a live consumer reproduced after the first fix landed. The credentialless build now starts a loopback-only HTTP mock registry per run, publishes each verified private tarball and a matching packument under it, rewrites only the tarball URL to that local `http://127.0.0.1` address, and scopes a run-local npmrc override to the affected package scopes so `pnpm install --frozen-lockfile --prefer-offline` resolves and fetches entirely from the loopback mirror — never presenting as a non-registry resolution and never contacting the private registry — while public dependencies remain installable from the public registry.
