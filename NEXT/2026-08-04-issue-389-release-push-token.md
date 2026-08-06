---
date: 2026-08-04
issue: 389
title: Give the changelog release a push token the branch ruleset accepts
---

`changelog-release.yml` ends with an `--atomic` push of the snapshot commit and
its tag straight to the default branch. Every Verjson repository carries an
identical `main-protection` ruleset that forbids exactly that, and whose only
bypass actors are `OrganizationAdmin` and Renovate. `GITHUB_TOKEN` is neither, so
the wiring every adopter copied could not complete a release:

```
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote: - Changes must be made through a pull request.
 ! [remote rejected] v0.4.0 -> v0.4.0 (atomic transaction failed)
```

The release half of ADR 0038 had therefore never run to completion anywhere —
none of the three older adopters has a `release:` commit on its default branch.
ADR 0038's 2026-08-01 amendment fixed the token *permission*; this is the
separate *ruleset* gate hit at the same line.

Release callers now pass an admin-scoped `push_token`. That is verified rather
than reasoned: `verjson-temporal-kit` re-dispatched with `ORG_ADMIN_TOKEN` and
landed `release: v0.4.0` with a matching tag. The trade-off — a release job
holding a wider credential than the repository-scoped default — is recorded in
ADR 0052 together with the two alternatives that were weighed and deferred.

`docs/changelog/README.md` documents the release caller's `push_token` for the
first time; never showing it is why adopters reached for `GITHUB_TOKEN` by
analogy with the validation caller. The generated contract test now rejects that
wiring statically, because the real rejection needs a real remote carrying a real
ruleset and the fixture repository has no remote — the same blind spot as #309,
where the failure lived past the last thing a pull request could check.
