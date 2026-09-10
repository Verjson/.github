# 0168 — Correct the Authn required workflow baseline after the activation trial

- **Date:** 2026-09-10
- **Status:** Accepted
- **Issue:** [#1154](https://github.com/Verjson/.github/issues/1154)
- **Category:** organization rulesets and workflow trust — sensitive class
- **Supersedes:** only the literal `4ff7bae1844df5eaad9056814e13dac1d786969d` workflow/baseline binding in [ADR 0167](../0167-controlled-authn-required-workflow-activation/README.md); its owner-authorized activation order, rollback requirements, and receipt gates remain in force

## Context

The first controlled required-workflow run,
[34425797400](https://github.com/Verjson/verjson-authn/actions/runs/34425797400),
failed before package acquisition. Its pinned workflow requested `@verjson/authn`
1.0.3, while Authn's protected `CI_SECRETLESS_PACKAGE_POLICY` permits 2.0.0.
Organization ruleset `21750617` was restored to its exact saved
`evaluate` image at `2026-09-10T01:36:54.347Z`, preserving the old workflow pin,
release App exception `4583107`, and consumer enforcement `21522093`.

Authenticated inspection of consumer main
`3160f49782ea17632b19122873466b5c5556b0e2` confirms that the existing local
type-surface caller and protected policy both select 2.0.0. GitHub Packages lists
the published version as package-version ID `1198472555`, and its immutable
`CHANGELOG/v2.0.0.md` snapshot exists. The current auxiliary-source pin
`63a0bb826eb0b707da5e592f7fd4070627ec71ab` is a main-branch ancestor with its
`NEXT` directory available; it does not need changing for this correction.

## Decision

Replace the stale literal compatibility request with exact version 2.0.0 in the
canonical required workflow and its strict validator. Keep the existing immutable
node-ci pin `c973a841694a41bf0b9bcd70432f64850cba0850`, package allowlist,
auxiliary-source request, scoped credential boundary, and hosted execution policy.
Do not broaden the consumer package policy to admit the obsolete request.

After this correction passes independent review and merges, the owner-authorized
rollout may repin the staged organization rule to the exact protected-main commit
containing this corrected workflow. Record that immutable SHA and verify the full
evaluate image before reactivation. This narrowly replaces ADR 0167's old literal
workflow binding; it does not grant general repin or activation authority.

Preserve ADR 0167's controlled sequence: owner-authorized activation, a new real
consumer PR event, exact-head canonical run verification, and a follow-up merge
receipt before separately coordinating retirement of `21522093`. Retain the sole
release App bypass and all scope restrictions. On another failed or absent required
run, return to the saved pre-activation evaluate image after verifying the live
postimage. Neither a configuration change nor a mocked test closes the rollout.

## Verification boundary

The exact dependency-lock validator extracted from node-ci commit
`c973a841694a41bf0b9bcd70432f64850cba0850` was executed in disposable fixtures
with the real current consumer package manifest, lockfile, protected policy, and
canonical compatibility input. No credentials were supplied and no packages were
downloaded. Version 1.0.3 exits 1 with the protected-policy authorization error;
2.0.0 exits 0 silently. The checked-in policy fixture and strict-validator tests
preserve both cases. Live acquisition, type-surface execution, and the post-activation
canonical receipt remain required rollout evidence.
