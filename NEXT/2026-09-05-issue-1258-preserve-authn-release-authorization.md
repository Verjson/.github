---
date: 2026-09-05
issue: 1258
impact: patch
title: Preserve release authorization during authn workflow migration
---
Keep the sole release-authorization App bypass in the authn ruleset migration so dispatched releases remain possible. Add a guarded staging path that updates the existing organization rule in evaluate mode without activating it, with exact preimage/postimage verification and rejection of widened bypasses.
