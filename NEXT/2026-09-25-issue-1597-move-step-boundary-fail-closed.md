---
date: 2026-09-25
issue: 1597
impact: patch
title: Fail closed when a moved workflow step's boundary can't be found
---

`move_step_before_guard`'s end-of-step scan accepted any line indented exactly
six spaces and starting with `- `, and silently fell back to end-of-document
when none matched. Addressing the non-blocking AI-review follow-up from
#1596: the scan now requires an actual step marker (`- name: ` or
`- uses: `), and raises `SystemExit` naming the drift instead of defaulting
to end-of-document, matching this generator's existing fail-closed pattern
for every other marker in the same function. No change to the generated
`node-ci-protected.yml` at the current tree.
