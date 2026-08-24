---
date: 2026-08-24
issue: 1019
impact: minor
title: Support reviewed pnpm dependency acquisition for container candidates
---

Allow container-candidate adopters to select an integrity-pinned pnpm 9 lockfile while preserving exact private-package scope, lifecycle isolation, credential-free Docker delivery, and recursive rejection of executable dependency configuration in committed lockfiles.

ADR 0127 records the package-manager, lockfile, registry-scope, and token-delivery trust boundaries. npm remains the default for existing adopters.
