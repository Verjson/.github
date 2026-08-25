---
date: 2026-08-25
issue: 1084
impact: minor
title: Separate dependency supersession observation from terminal mutation
---

Define an organization-neutral, least-privilege GitHub App contract for documenting and closing dependency-update pull requests that are completely superseded by newer bot updates.

ADR 0136 keeps detection read-only, requires independent live revalidation, scopes each short-lived write token to one repository, and makes observe-only evidence plus a disposable canary prerequisites for enabling closure.
