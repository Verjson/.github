---
date: 2026-08-16
issue: 835
impact: patch
title: Make generated changelog callers publish the live required check
---

Generated changelog callers use the `changelog` job prefix while invoking the consolidated `generated-artifacts.yml` workflow, so every changelog-enabled mode publishes the active ruleset's exact `changelog / validate` context.

The generated contract and standard-library-only central audit bind the exact caller mapping at `.github/workflows/changelog.yml`, immutable pin, exact `with:` inputs, and declared context to that live requirement. Every workflow filename is inspected, so renamed generated copies, legacy validation callers, duplicate paths, job-level names, matrices, extra inputs, typos, and comment lookalikes fail closed. The staged rollout binds that inspector to merged canonical bytes and rejects override paths before conformance. ADR 0106 supersedes the earlier context-name decision without weakening organization protection, while `workflow` remains a compatibility command for existing automation.
