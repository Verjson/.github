---
date: 2026-09-14
id: 20260914T091500Z
title: Publish a deferred org CI run as its own failing check instead of a silent green
impact: minor
---

`node-ci.yml` and the generated `node-ci-protected.yml` now publish a separate
`deferred-ci` check that runs only when `eligibility` defers the lane on a pending
`renovate/stability-days` status, and that check fails. The required `ci / build-test`
context is unchanged and still reports success on a defer, so no held Renovate pull
request wedges — but a deferred head is no longer indistinguishable from an executed,
passing one in `statusCheckRollup`.

`Verjson/verjson-cli#251` is why. While the release-age gate was pending, `build-test`
skipped all 26 of its real steps and still reported green to branch protection; that
repository's `STALE_CLI_PROJECTS_LOCK` guard never ran, and a lockfile violating a
deliberate version hold passed a required check that had verified nothing.
[ADR 0156](../docs/decisions/0156-deferred-ci-legible-to-merge-gate/README.md) had
already made the deferral legible through a titled check-run annotation plus an opt-in
`scripts/assert-no-deferred-checks.sh`; #251 showed that an opt-in surface nobody reads
does not hold. `statusCheckRollup` is the surface everybody reads.

`deferred-ci` pins `ubuntu-24.04` unconditionally rather than resolving the shared
self-hosted routing expression every other job uses. It checks nothing out, holds no
permissions, and runs one `echo` plus `exit 1`, so it consumes nothing ADR 0033's runner
policy protects — while a saturated or offline self-hosted pool would leave the check
`PENDING`, the ambiguous state this change exists to remove. The route is registered
as a reviewed exception in the runner-routing policy inventory, and the eligibility
script — shared byte-for-byte with the `ci-eligibility` composite action — now records
that `deferred-ci`'s error text names the pending release-age gate as the sole defer
cause, so a second defer reason cannot be added without generalizing that message.

This is a deliberate fleet-wide behavior change, recorded in
[ADR 0178](../docs/decisions/0178-publish-deferred-ci-as-its-own-check/README.md). In
every adopter, a Renovate pull request held on its release-age window now shows a red
`deferred-ci` check and a failed workflow run, and any caller asserting a fully green
rollup — including this organization's agents and its `--admin` merge procedure — will
refuse to merge it. GitHub branch protection and native auto-merge are unaffected,
because both evaluate only the contexts a ruleset names and `deferred-ci` is
deliberately not one of them; adding it to `config/required-check-bindings` would
reintroduce the `#191` wedge, because nothing re-fires a deferred run on the same head.

The alternative of making `ci / build-test` itself non-satisfying was considered and
rejected for a mechanism-specific reason rather than cost: a deferred run is never
re-dispatched on the same head, so a non-satisfying required context blocks until
Renovate happens to rebase, with no bound and no reviewer-triggerable recovery. ADR 0178
records that trade-off, the rejected `neutral` option, and the one follow-up this leaves
open — `ai-privileged-merge.yml` now rejects a deferred promotion correctly but with a
message that does not name the deferral.
