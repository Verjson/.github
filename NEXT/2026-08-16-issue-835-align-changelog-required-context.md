---
date: 2026-08-16
issue: 835
impact: patch
title: Make generated changelog callers publish the live required check
---

Generated changelog callers use the `changelog` job prefix while invoking the consolidated `generated-artifacts.yml` workflow, so every changelog-enabled mode publishes the active ruleset's exact `changelog / validate` context.

The generated contract and PyYAML-backed central audit bind the exact caller mapping, immutable pin, changelog input, and declared context to that live requirement; job-level names, matrices, and comment lookalikes fail closed. ADR 0106 supersedes the earlier context-name decision without weakening organization protection, while `workflow` remains a compatibility command for existing automation.
