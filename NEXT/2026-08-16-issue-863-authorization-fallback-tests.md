---
date: 2026-08-16
issue: 863
impact: patch
title: Lock authorization fallback outcomes
---

Complete-authorization behavioral tests now lock the GitHub-visible conclusion, title, and summary for superseded and unknown AI-review outcomes. Both paths must remain neutral human fallbacks that cannot request App approval, emit AI authority, or report success or failure while exact-head trust checks pass.
