---
date: 2026-08-13
issue: 329
title: Replace the release admin PAT with a repository-scoped App token
impact: patch
---

Canonical Node release callers now pass the dedicated release App identity
instead of `ORG_ADMIN_TOKEN`. The reusable workflow validates the App client ID
and mints a short-lived installation token constrained to the current repository
and Contents write before atomically pushing the immutable snapshot and tag.

ADR 0099 records the intentionally organization-wide installation and credential
availability trade-off, as well as why the first real canonical release is the
only faithful canary for the exact protected default-branch ruleset.
