---
date: 2026-09-10
issue: 1285
impact: major
title: Require main-only environment storage for privileged App keys
---

Move release, merge and AI review key consumption inside caller-owned main-only
environments. Generated callers select role environments instead of forwarding
App private keys; model/npm credentials retain explicit grants. Validate live
environment policy before admitting key jobs, preserve rearm event filtering and
provide a metadata-only operator audit plus staged shared-ruleset rollout.
Consumers must provision environments and regenerate before broad copies can be
removed; merging this contract alone does not complete exposure removal.
