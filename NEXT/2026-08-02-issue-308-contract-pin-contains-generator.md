---
date: 2026-08-02
issue: 308
title: Recommend a contract pin that actually contains the generator
---

Consumers were told to generate their changelog callers against `1486d44…`, a commit that
predates `scripts/gen-changelog-caller.sh`. Fetching the generator at `contract_ref`
therefore 404s, and `verjson-authn` had to carry a second `generator_ref` pointing
somewhere else to keep its contract test hermetic — two pins for one contract, which is the
drift #304 reported wearing a different hat.

The migration guide now names a single pin containing both the generator and the digest
verification from #304, with the three generation commands spelled out.
`scripts/contract-pin.test.sh` reads that literal out of the guide and asserts it resolves
to a commit, that `gen-changelog-caller.sh` is readable at it, and that the generator there
supports all three modes the documented commands invoke. Pinning `1486d44…` again fails
four assertions. This is the #287 lesson applied to a commit rather than a tag: a
documented literal nothing checks will eventually name something that does not exist.

The guide also now states the ordering that removes the need for a migration bypass —
generate the files and land the snapshot pull request before `changelog.yml` exists in the
consumer, so `check_pr` never runs against the pull request that consumes fragments.
`verjson-identity-contracts` added a permanent `if: github.event.pull_request.number != 16`
escape hatch for want of this, which every later copier inherited
(verjson-identity-contracts#26); `verjson-browser-agent` and `verjson-cli-projects`
sequenced it this way and needed none.

The check materialises the pin on demand rather than assuming it is present. `actions-ci`
checks out with `fetch-depth: 1` since #234 (ADR 0045), so the pinned commit is normally
absent from the local object store — the first version of this check passed on a developer
machine with full history and failed in CI for that reason alone. It now uses the same
`fetch_pinned_commit` shape `node-workflow-pins.test.sh` established, and was verified
against a genuinely shallow clone.
