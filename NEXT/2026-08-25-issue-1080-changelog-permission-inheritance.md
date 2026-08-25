---
date: 2026-08-25
issue: 1080
title: Fail closed on inherited changelog check permissions
---

The required-check classifier now requires the exact workflow-level `contents: read`
permission on a workflow that publishes the changelog contract context, preventing the
generated job from silently inheriting broader authority. Ambiguous duplicate top-level
keys, including mixed `on`/YAML-1.1 `true` trigger aliases, now fail closed before
contract extraction. Regression coverage binds the classifier to the canonical
generator output and also records the accepted trailing-comment and block-scalar
formatting raised in #1078 and #1079.
