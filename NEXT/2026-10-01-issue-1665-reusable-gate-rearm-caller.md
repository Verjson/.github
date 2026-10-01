---
date: 2026-10-01
issue: 1665
impact: patch
title: Make the generated gate re-arm caller reusable
---
The generated gate re-arm caller now supports local workflow reuse and runs directly only for opened, reopened, and synchronize pull request events. Lifecycle-only events stay in the lifecycle caller, which invokes the local gate caller once; label-only re-arming remains in the label caller.
