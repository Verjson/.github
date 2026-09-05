---
date: 2026-09-05
issue: 1261
impact: patch
title: Align consumer runner policy with canonical generated callers
---

Accept the exact generated changelog PR gate on disposable hosted capacity and the
existing release routing expression without changing generator output or moving
PR-authored code onto persistent runners. Reject modified execution fields and
unreviewed selectors; exercise generated callers in consumer-policy regression tests.
