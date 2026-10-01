---
date: 2026-10-01
issue: 1669
impact: patch
title: Support the Node 26 npm CLI layout
---

Resolve npm's CLI from the validated Node toolcache and invoke it with the validated Node executable. Keep the tool prefix read-only and preserve the credentialless protected sandbox when Node 26 places npm's package under `lib/node_modules/npm` but its launcher still looks under `bin`.
