---
date: 2026-08-10
issue: 716
title: Generate the universal AI review caller
---

Generate the repository-local AI review dispatcher alongside the re-arm and
privileged-merge callers so universal gate adoption cannot fail with a workflow
dispatch 404 after publishing an authorization receipt.

Keep the review completion job within its least-privilege workflow token while
the terminal privileged merge retains current maintainer-permission revalidation.
