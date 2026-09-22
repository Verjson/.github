# 0201 — Secret-bearing fleet reports run only from the default branch

- **Date:** 2026-09-22

## Context

Issue #1506 adds a scheduled inventory workflow that receives the organization-wide, read-only Renovate Compatibility App private key. `workflow_dispatch` can select a branch, and GitHub runs the workflow definition from that ref. A repository writer could therefore dispatch a branch that changes the workflow to expose the private key, despite the installation token being limited to read-only contents access.

## Decision

The fleet report runs only on a push to `main` or on its scheduled trigger. It has no `workflow_dispatch` trigger. Both remaining triggers execute the default-branch workflow, which is the only code allowed to receive the App private key.

## Consequences

The report cannot be requested manually from a selected ref. It continues to run weekly and after changes to its workflow or inventory implementation. Any future manual trigger must preserve the default-branch code boundary before it can receive the App private key.
