# 0167 — Activate the staged Authn required workflow under explicit owner authority

- **Date:** 2026-09-10
- **Status:** Accepted
- **Issue:** [#1154](https://github.com/Verjson/.github/issues/1154)
- **Category:** organization rulesets and workflow trust — sensitive class
- **Supersedes:** only the pre-activation green-receipt ordering in [ADR 0155](../0155-de-escalate-the-authn-type-surface-required-workflow/README.md) for this rollout

## Context

The owner explicitly requested activation of organization ruleset `21750617`
under its human gate, followed by consumer verification and a separately
coordinated retirement of repository ruleset `21522093`.

The reviewed rule is in `evaluate`, pinned to protected workflow commit
`4ff7bae1844df5eaad9056814e13dac1d786969d`. Its full image and the consumer
preimage pass the canonical evaluate dry-run. Authn's compatibility script and
auxiliary-source pin are now present on `main`; the earlier missing-prerequisite
and package-access blockers have been resolved by the consumer.

Fresh Authn PR events have produced local CI but no canonical required-workflow
receipt. That observation does not prove that evaluation mode never executes
workflows: [GitHub documents evaluation-mode execution](https://docs.github.com/en/enterprise-cloud%40latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#using-evaluate-mode-for-ruleset-workflows).
The platform cause remains unresolved. The owner has explicitly selected a
controlled activation to obtain the real receipt, accepting the temporary risk
that an unsuccessful required workflow can block Authn merges.

## Decision

For this rollout, activation precedes the first successful canonical receipt.
This is an explicit owner-authorized sequencing exception, not a general waiver
of the human gate or permission to activate other unproven required workflows.

Change **only** `enforcement` from `evaluate` to `active`. Keep the exact rule ID,
repository/default-branch scope, protected workflow path/ref/SHA, and the sole
release-authorization App `4583107` bypass from [ADR 0163](../0163-preserve-release-authorization-in-authn-required-workflow/README.md).
Do not grant the merge App a bypass. Keep consumer rule `21522093` active.

Use the [reviewed one-off procedure and exact source](https://github.com/Verjson/.github/issues/1154#issuecomment-5611186784),
SHA256 `17afbc5e573aeeb3f23183d2da78e4d4f32773d70caee9e9f63d230b6db629f5`.
It verifies all three canonical files against the immutable pin before importing
the existing validator, verifies reachability from protected `main`, and compares
the complete staged image. It saves the trigger snapshot, preimage, active
candidate and evaluate rollback payload; immediately before PUT it re-reads both
the complete image and `updated_at`. After PUT it verifies the complete postimage
and records the server's activation timestamp. The existing validator remains
unchanged; no general-purpose activation escape hatch is added.

GitHub offers no conditional compare-and-swap for this mutation. The immediate
re-read narrows but cannot eliminate an administrator race. An uncertain response
or unexpected postimage requires live inspection; never blindly overwrite it.

## Acceptance and rollback

Post the activation timestamp, unchanged workflow SHA and pre-trigger maximum
run ID on #1154 and [Authn #314](https://github.com/Verjson/verjson-authn/issues/314).
The Authn owner then triggers a real PR event and verifies its exact head with
the canonical `verify-run` command. A same-named consumer check does not qualify.
Confirm that a follow-up PR still merges before separately coordinating retirement
of the name-only consumer rule. Activation alone does not close #1154 or #314.

If the required workflow is absent or fails and blocks consumer progress, return
the organization rule to the saved `evaluate` image after confirming the live
image still equals this activation's exact postimage. Preserve the release App
exception, the immutable pin and consumer enforcement; do not widen bypasses or
retire `21522093` to work around a failed rollout. Record the failure and verified
rollback on the same issues before another activation attempt.

## Verification boundary

The canonical dry-run, payload comparison and independent procedure review prove
the proposed control-plane change. Existing behavioral tests cover exact images,
spoofed checks, stale heads and required-workflow provenance. Successful workflow
execution and follow-up mergeability require live consumer receipts after
activation; they are not inferred from local tests or a successful PUT.
