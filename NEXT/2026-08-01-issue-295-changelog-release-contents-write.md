---
date: 2026-08-01
issue: 295
title: changelog-release grants its pushing job write authority
---

`changelog-release.yml` declared a workflow-level `contents: read` and no job override,
so the token reaching its final atomic push was read-only. A called workflow's
`permissions` block is the cap rather than the caller's, so a consumer granting
`contents: write` and passing `push_token: ${{ secrets.GITHUB_TOKEN }}` still got a
read-only token: every release generated its snapshot, verified its exact tag, then died
on the push with `remote: Write access to repository not granted` / HTTP 403, leaving no
tag, release or package. Evidence: verjson-identity-contracts run 30724326491, tracked
downstream as Verjson/verjson-identity-contracts#24.

The `release` job now declares `contents: write`; the workflow-level default stays
`contents: read`. Nothing widens at the caller — a caller withholding `contents: write`
still yields a read-only token, since its grant is the outer cap.

ADR 0038 already required release callers to hold contents-write credentials, so this
restores a recorded invariant rather than deciding anything new; that ADR carries a dated
amendment instead of a new number. `scripts/changelog-release-permissions.test.sh` (wired
into `actions-ci.yml`) pins the shape: the grant scoped to the pushing job, the
workflow-level default a bare `contents: read`, and the commit+tag push still atomic.

Consumers pinned to a pre-fix revision must re-pin both the `uses:` ref and `contract_ref`
before re-dispatching a release.
