---
date: 2026-09-23
issue: 1455
title: Require changelog fragments for release-relevant changes
impact: patch
---
Require a new valid `NEXT/` fragment when a pull request changes behavior, configuration, code, documentation, or pins without touching a dependency manifest.

The gate now fails closed for new repository paths while retaining narrow exemptions for changelog stores and test-only files. Executable GitHub workflows and local action metadata named `action.yml` or `action.yaml` remain release-relevant in any directory, even when their paths look test-only. Canonical generated contract tests cover the accepted fragment, deleted follow-up fragment, missing fragment, and executable-path precedence cases.
