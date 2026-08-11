---
date: 2026-08-11
issue: 742
title: Route the authorization arm through organization runner lanes
---

Route the trusted `pull_request_target` authorization arm through `VERJSON_LANE_TRUSTED` and `VERJSON_LANE_FALLBACK` instead of bypassing configured organization capacity with a hardcoded hosted runner.

ADR 0093 supersedes ADR 0091 only for runner placement. The arm retains its base-branch-only event boundary, no-PR-checkout invariant, exact-head receipt, App permissions, timeout, and non-vetoing human path.
