---
date: 2026-09-23
issue: 1477
impact: patch
title: Verify non-gate module declarations against imports and command use
---

Require every declared CI-gate library module to be imported by its exact tracked path
from another CI-gate script and never invoked as a command on a tracked Actions execution
path, regardless of relative, workspace-variable, trusted-checkout, or punctuation form.
Ambiguous imports, relative-package and module-attribute filename collisions, shell
continuations, and parse failures that mention a gate path fail closed.

The grouping contract now carries end-to-end source and workflow mutations, including a
same-basename import collision, and points discovery failures to ADR 0193 and the
`NON_GATE_MODULES` declaration list.
