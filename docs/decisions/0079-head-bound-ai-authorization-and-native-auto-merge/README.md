# 0079 — Head-bound AI authorization and native auto-merge

> **Partially superseded by [ADR 0081](../0081-event-driven-terminal-ai-promotion/README.md):**
> native auto-merge and GitHub-owned CI waiting could not satisfy the organization
> code-owner and last-push approval rules. The head-bound paid-review and App
> authorization decisions remain in force.

- **Date:** 2026-08-08
- **Status:** Accepted
- **Issues:** [#632](https://github.com/Verjson/.github/issues/632), [#650](https://github.com/Verjson/.github/issues/650)
- **Supersedes:** [ADR 0017](../0017-two-stage-ai-merge-gate/README.md) for merge orchestration and [ADR 0063](../0063-required-workflow-events-are-bridged/README.md) for re-arm dispatch
- **Amends:** [ADR 0036](../0036-separate-pr-review-from-privileged-merge/README.md) by replacing run artifacts with an explicit Checks API authorization

## Context

The old gate made a paid review job wait for ordinary CI and made a privileged
job wait again before merging. Those waits occupied runners for work GitHub's
branch policy already performs, and unrelated check transitions could cause a
new gate run and another model charge. A `workflow_dispatch` re-arm also ran on
the default branch rather than the PR head, so it could not replace the failed
required `gate` context. Eight days of this behavior incurred roughly $400 in
model API charges.

The security boundary remains strict: PR-controlled workflow code must not
receive secrets, a verdict for one head must never authorize another, and an
inconclusive or blocking review must not enable a merge.

## Decision

Use `gate-rearm.yml`, loaded by `pull_request_target` from the trusted base, as
the sole automatic arm. For each current same-repository PR head it creates an
`AI review authorization` check-run through the Checks API using a dedicated
GitHub App, not the repository's shared `github-actions` installation. The arm
gives the check a random external ID and publishes an immutable, run-owned
artifact receipt naming the repository, PR, head, check ID, arm run/attempt,
external ID, dedicated App ID/slug, and details URL. It dispatches the
default-branch review workflow with those exact identities. Duplicate events
for a head reuse its existing check and spend no
model tokens. Only an explicit `re-review` label may replace a same-head result;
a changed head receives a new authorization. Fork PRs fail the authorization
without dispatching secrets.

The model workflow has no `pull_request` or `pull_request_target` trigger. It
downloads the uniquely named receipt from the exact arm run, verifies GitHub's
artifact digest and strict receipt schema, and requires the receipt to name the
exact dedicated-App check ID, external ID, head, PR, and run. It validates this
before reading the head, permits the model
only `Read`, `Grep`, and `Glob`, and completes that exact check. Blocking,
missing, malformed, stale, or errored verdicts complete it as failure. A
successful exact-head verdict completes it as success and dispatches the
trusted default-branch promotion workflow.

The promotion workflow repeats the receipt, artifact-digest, arm-run, live PR,
and exact successful dedicated-App check verification. Before the check can
become successful, the same dedicated App uses its receipt-bound token to
submit an approving review for the exact reviewed commit and reads that review
back by ID. A rejected, missing, differently authored, or stale-head approval
completes the authorization as failure. Promotion also requires GitHub's live
`reviewDecision` to be `APPROVED`; `REVIEW_REQUIRED` remains fail-closed. It then requests
GitHub native auto-merge with `SQUASH`. It does not read ordinary CI and does
not merge with a ruleset bypass; GitHub owns waiting for all configured
required checks. Holds, drafts, forks, stale heads, missing permissions, and
failed or inconclusive checks remain fail-closed. Duplicate promotions are
idempotent.

Arm receipts use the repository's 90-day artifact-retention maximum so a
long-lived hold can be removed without another model call. Hold removal reuses
only a successful exact-head authorization whose receipt is still uniquely
available. If that evidence has expired or become ambiguous, the arm fails red
with an explicit administrator-recovery message and never automatically
dispatches another paid review. Recovery must restore independently verified
authorization evidence or require an explicit maintainer `re-review` decision.
Clearing a hold or draft never silently buys another review. A failed or
inconclusive same-head authorization produces an actionable PR notice requiring
an intentional `re-review` label. A receipt-proven in-progress authorization
produces wait guidance and is not redispatched; missing or ambiguous pending
evidence produces administrator-recovery guidance and fails red.

## Ruleset migration and rollback

Create and install a dedicated GitHub App with Checks read/write and pull
requests read/write on each managed repository. Store its numeric ID and slug in `AI_REVIEW_APP_ID` and
`AI_REVIEW_APP_SLUG` organization variables, and its private key in the
restricted `AI_REVIEW_APP_PRIVATE_KEY` organization secret. The private key is
available only to trusted `pull_request_target` arm code and trusted
default-branch completion code; it is never passed to the model action or a
PR-controlled workflow. Receipt artifacts are intentionally readable and are
not bearer credentials: another workflow can copy their nonce, but it cannot
alter the immutable artifact, change the check ID named inside it, or mint or
complete a check as the dedicated App.

The shared `github-actions` slug plus a trusted-looking `details_url` is
explicitly insufficient: any same-repository workflow can reproduce those
fields. The dedicated App identity and exact immutable receipt are both
required. Repository workflow tokens receive no `checks: write` permission.

The pull-request permission is an external deployment prerequisite, not a
workflow-side permission escalation: an organization owner must add
`Pull requests: Read and write` to `verjson-ai-review-authorization`, approve
the permission change, and reinstall or approve the installation if GitHub
requests it. Keep both AI workflows disabled until that installation can mint a
token with `checks:write` and `pull_requests:write` and a controlled PR proves
the exact-head App approval, successful App check, and terminal native merge.
Rollback first disables both workflows, then removes the App's pull-request
permission after restoring the prior human/admin merge path; no model review is
automatically retried during either transition.

Deploy the workflows and generated callers first. **Ruleset migration remains
unavailable** until the dedicated App provisioning blocker
[#641](https://github.com/Verjson/.github/issues/641) is fulfilled and a test PR
head has produced a receipt-bound check from the
exact dedicated App, review has completed that same check, and native auto-merge
has remained pending on an ordinary required CI check. Only then configure the
ruleset to require `AI review authorization` from that dedicated App and remove
the old required-workflow `gate` requirement. Do not require both:
the retired workflow context would keep every PR blocked. Confirm that native
auto-merge and squash merging are enabled and that the promotion credential can
request auto-merge but is not configured as a bypass actor.

Before enabling `verjson-core-checks=enforced` for an adopter, an organization
owner must also prove that every `AI_REVIEW_*` organization variable consumed by
the generated arm and review callers is visible to that repository. This includes
the App identity, authority, provider, model, and budget variables for both the
primary review and re-review paths. Separately verify that
`AI_REVIEW_APP_PRIVATE_KEY` and the configured provider secret (including
`ANTHROPIC_API_KEY` when Anthropic is selected) are visible without reading or
recording their values. Variable visibility does not prove secret visibility or
that the App is installed with the required permissions.

The adoption order is therefore: install the App and verify its permissions;
make the complete variable and secret families visible; deploy the generated
callers; then set `verjson-core-checks=enforced` and use a controlled pull request
to prove the arm, exact-head review, authorization, and terminal promotion. The
property is last because it activates the required arm immediately; enabling it
before its organization configuration is reachable creates a required check that
can only fail.

Rollback reverses that order: restore the immutable old required workflow and
verify its context appears on a test PR before removing the new required check.
Then restore the prior workflow revision and revoke the App private key.
Existing successful authorizations
are head-bound and do not become reusable on another commit during either
transition.

### 2026-08-10 clarification — superseded promotion events are terminal no-ops

Issue [#723](https://github.com/Verjson/.github/issues/723) exposed an expected
workflow-run race: ordinary CI completed for an authorized head after the PR had
already advanced. Terminal promotion must still validate its default-branch and
canonical-workflow provenance, then compare the authoritative live PR head with
the authorized head before verifying the immutable receipt. A closed PR or a
different live head is a successful no-op because there is no authorized
mutation left to perform. The current open head continues through full receipt,
App approval, required-CI provenance, and exact-head merge verification. This
does not make authorization reusable; it prevents obsolete events from
misreporting a security rejection as an operational failure.

## Consequences

- One head pays for at most one automatic review; an explicit maintainer
  re-review is the only same-head exception.
- No gate or privileged runner waits for ordinary CI.
- Ordinary CI can finish before or after review without triggering more model
  work; native auto-merge observes it.
- The dedicated App approval satisfies the organization review rule without
  giving the promotion token a ruleset bypass or weakening review requirements
  for unrelated pull requests.
- Repositories must install the generated trusted arm and promotion callers and
  migrate the required-check identity deliberately.
- Follow-up issue creation and branch deletion can no longer be coupled to a
  privileged synchronous merge. They require separate post-merge automation if
  the repository does not already provide it ([#640](https://github.com/Verjson/.github/issues/640)).

## Contract-test migration

Focused coverage was not discarded with the polling implementation:

| Retired contract | Event-driven replacement |
| --- | --- |
| `gate-queue`, `ci-wait-fail-closed`, `required-checks-skip-poll`, `toolchain-missing`, `self-job-exclusion` | `event-driven-authorization` proves no wait/check loop; `native-automerge` proves CI-pending delegation and fail-closed promotion |
| `gate-rearm`, `required-workflow-provenance`, `entry-workflow-provenance` | `arm-receipt` executes exact run/artifact/digest/check binding mutations; `gate-dispatch` executes dispatch failure handling |
| `hold`, applicable `require-secrets` cases | `native-automerge` executes hold/draft/fork/credential cases; `event-driven-authorization` audits that shared workflow tokens never receive Checks write |
| `dispatch-permission` | `gate-dispatch` and `native-automerge` execute dispatch, idempotency, GraphQL-error, and privileged-token failure paths |
| `reusable-workflow`, `gate-rearm-caller-contract`, `privileged-merge-caller-contract`, `privileged-merge-pin` | both generated-caller contracts retain immutable/thin caller, exact input, secret, runner, canonical target, and default-branch provenance coverage |
| `followup-issues`, `merge-branch-cleanup` | No authorization assertion was silently weakened; the behavior moved to tracked post-merge work in #640 |

Model retry, semantic verdict, review publication, freshness, diff acquisition,
fast-lane classification, target visibility, and budget-exhaustion suites remain
unchanged and continue to run in the merge-gate group.

### 2026-08-11 clarification — remove superseded unregistered extractors (#733)

The migration table above named the current replacement suites, but the retired
`gate-rearm.test.sh` and `hold.test.sh` files remained in the repository. They were
not registered in `scripts/actions-ci-groups.tsv` and still searched for step IDs
removed by this ADR, so their coverage claims were both stale and invisible to CI.

Those files are removed. The registered `gate-hold-disable.test.sh` now carries the
live arm's hold and event-rearm truth table, including normalized hold release,
ready-for-review, title release, unrelated-label suppression, metadata API failures,
empty/null/missing and malformed metadata, closed/merged states, receipt reuse, and
explicit review lanes. The registered `native-automerge.test.sh` now carries every
terminal hold spelling plus empty/null and malformed metadata against the current
privileged promotion step. The caller contract pins the canonical arm's exact
permissions, concurrency, trusted metadata sources, input validation, and absence of
a head checkout, then delegates behavioral claims to the registered arm, event, and
receipt suites that actually own them. Existing authority-envelope, App identity,
exact-head, and required-CI coverage remains unchanged. This is a coverage repair
only; no workflow logic or authority changes.

### 2026-08-11 clarification — provider-neutral verdict confirmation (#739)

Every model adapter now ends at one provider-neutral verdict boundary. Adapters own
their transport envelope, terminal-state checks, usage evidence, and extraction of
exactly one assistant JSON object; they do not independently decide whether that
object authorizes a merge. The canonical validator documents accepted field aliases,
normalizes structured review locations, projects one strict verdict shape, and
enforces blocking/findings equivalence plus non-empty review-first guidance for
sensitive changes.

Confirmation is deterministic and local: it makes no additional model call. Invalid
or ambiguous output fails closed with bounded field-path diagnostics that exclude the
raw model response and pull-request diff. Cross-provider conformance tests pass the
same representative response through the Claude workflow path and the OpenAI and
DeepSeek transport adapters before applying the canonical validator. This keeps model
integration generic without guessing arbitrary prose into an approval.

### 2026-08-13 clarification — prompt canonical verdict field names (#771)

The shared provider-neutral prompt must request the same strict item shapes that the
canonical validator returns and the deterministic renderer consumes. In particular,
`review_first` entries use `{location, why}`; `reason` belongs to blocking findings,
not to the canonical review-first shape. The validator continues to accept `reason`
and `rationale` as compatibility aliases for historical output and ordinary model
variance, but the first-party prompt does not ask providers to spend that flexibility.

Contract coverage binds the shared prompt supplied to Claude, OpenAI, and both
DeepSeek passes to the renderer's `review_first[].why` access, then confirms canonical
and aliased provider outputs converge before publication. This restores the existing
provider-neutral verdict boundary and does not change review or merge authority.
