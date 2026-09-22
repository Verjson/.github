---
date: 2026-09-22
issue: 1502
impact: patch
title: Lint tracked shell scripts in Actions
---

The platform Actions group now runs warning-level ShellCheck over every tracked shell script; existing warning-level findings are fixed or narrowly annotated at their source.

This closes the gap between workflow `run:` block linting and standalone scripts. The CI manifest contract test protects the lint command’s Actions registration.
