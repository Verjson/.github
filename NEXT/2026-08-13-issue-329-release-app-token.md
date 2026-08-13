---
date: 2026-08-13
issue: 329
title: Replace the release admin PAT with a repository-scoped App token
impact: patch
---

Canonical Node release callers now pass the dedicated release App identity
instead of `ORG_ADMIN_TOKEN`. The reusable workflow rejects empty and numeric
legacy IDs, delegates the supported client-ID grammar to the pinned action, and
mints a short-lived installation token constrained to the current repository and
Contents write before atomically pushing the immutable snapshot and tag.

The input-free manual canary uses the trusted organization runner lane, exercises
the same organization ruleset and App bypass through its fixed protected
`develop` target, retains an Actions receipt, and atomically removes only refs
that still belong to its run. ADR 0099 records
that proof boundary and the intentionally organization-wide installation and
credential-availability trade-off.

The generated-caller contract tests now inspect complete in-memory output
without early-closing `grep -q` pipelines, so larger release callers cannot
turn a successful assertion into a nondeterministic `pipefail` failure.
