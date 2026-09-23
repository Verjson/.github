---
date: 2026-09-23
issue: 1383
impact: patch
title: Bind autonomous merge to independent review receipt
---

Autonomous terminal promotion now requires the latest exact-head verdict from an independently authorized non-App maintain/admin account, terminally revalidated before the merge App token is minted. The final merge boundary also rechecks draft, normalized hold labels, the `DO NOT MERGE` title marker, open state, exact head, and base immediately before the admin merge. Edited, dismissed, withdrawn, superseded, malformed, App-authored, permission-downgraded, and late-held attempts fail closed while the protected human merge path remains unchanged.
