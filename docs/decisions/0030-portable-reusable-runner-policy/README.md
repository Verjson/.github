# 0030 — Separate Verjson runner policy from reusable-workflow portability

- **Date:** 2026-07-28
- **Issues:** Verjson/.github#173, Verjson/.github#174
- **Category:** reusable workflows / runner security boundary
- **Supersedes in part:** ADR 0028 hosted routing for Verjson public validation

## Context

This repository is both Verjson's CI policy package and a public reusable
workflow package. A fixed `ubuntu-24.04` selector works for outside consumers
but violates Verjson's decision to avoid GitHub-hosted Actions. A fixed
self-hosted default has the opposite failure: another organization cannot
access Verjson's runner groups.

Reusing the `ubuntu-24.04` label on a self-hosted runner would conceal that
distinction and make a workflow's trust boundary ambiguous.

## Decision

Reusable workflows resolve runners in this order:

1. an explicit runner-label input, including a trusted persistent pool;
2. `[self-hosted, isolated, linux, x64]` when the caller belongs to `Verjson`;
3. GitHub-hosted `ubuntu-24.04` when the caller belongs to another organization.

Verjson-local jobs use the isolated selector directly. The merge gate retains
its explicit `[self-hosted, gate]` route for trusted private repositories and
accepts `runner_labels` from reusable callers.

A repository test rejects literal `ubuntu-24.04` and `ubuntu-latest` job
selectors and rejects hosted fallback expressions that are not bounded to
outside organizations.

## Delivery dependency

Do not merge this routing change until:

- `Verjson/verjson-github-runner#50` is merged and published; and
- the coordinated `verjson-cli-cloud` deployment PR has provisioned and proved
  the isolated pool required by #173.

This PR changes no live runner groups, repository access, billing, or cloud
resources.

## Consequences

- Verjson does not need GitHub-hosted Actions for its own workflows.
- Outside organizations can consume the public workflows without access to
  Verjson infrastructure.
- Trusted Verjson callers may continue to select persistent pools explicitly.
- The `ubuntu-24.04` label remains unambiguously GitHub-hosted.
