# Gate tries update-branch before holding on a conflict — 2026-07-20

Extended the `freshness` step in `ai-review-merge.yml` (ADR 0008): on
`mergeable == CONFLICTING` the gate no longer holds immediately. It now **first
attempts the same non-destructive `update-branch` merge** the BEHIND path uses,
then re-checks mergeability (waiting out the async UNKNOWN window like the initial
read). If the conflict was mere base drift, the merge clears it and the run steps
aside (`proceed=false`) so the resulting `synchronize` re-enters the gate against
the current base — same ergonomics as the BEHIND path. A **genuine** content
conflict (update-branch API fails, or still CONFLICTING afterwards) falls back to
the unchanged fail-closed hold + deduped `gate:branch-conflict` comment. Renovate
stays exempt (its author/branch check runs before the mergeable check, so no
update is attempted). Merge only — **no rebase/force-push**; still git-revertible.
Honest limit: a merge resolves drift but not overlapping-edit conflicts, and not
the squash-divergence patch-id case that only a rebase dedups (#55). Extended
`scripts/ci-gate/freshness.test.sh` (+4 cases: cleared→proceed=false, failed
update→hold, genuine conflict→hold, Renovate→exempt; the stub returns a
post-update mergeable once `update-branch` has logged), all 13 green + full
ci-gate suite green + YAML validates. Decision recorded as ADR 0013
(sensitive-class: org merge-gate behavior). Issue #56.

# tag-major: serialize the moving-tag force-push with a concurrency group — 2026-07-20

Follow-up hardening to #58 (from its code-review): `tag-major.yml`'s `retag-major`
job gains `concurrency: tag-major` so two releases published in quick succession
can't race on the `vX` force-push (last write wins deterministically). No change
on the common one-release path. Not sensitive beyond the already-reviewed release
automation surface.

# fix: pulumi-ci comment-on-pr is a true no-op on non-PR events — 2026-07-20

Fixes #47 (non-blocking AI-review follow-up from #46). The reusable
`pulumi-ci.yml` handed `comment-on-pr: ${{ inputs.comment-on-pr }}` (default
`true`) straight to `pulumi/actions@v7` on the live-preview step, with no
PR-context guard. On a `push` (or any non-`pull_request`) trigger there is no PR
to comment on, so a push-triggered invocation could hard-fail trying to post a
comment — the "graceful no-op on push" behavior asserted in #46 was never
actually exercised. Gated the value on the event context:
`comment-on-pr: ${{ inputs.comment-on-pr && github.event_name == 'pull_request' }}`
(`.github/workflows/pulumi-ci.yml`), so it resolves to `false` off a PR and the
preview still runs, just without commenting. Because the value is a pure GitHub
expression (not a shell block), it can't be executed in bash like the other
gate steps; pinned instead by extraction (`scripts/ci-gate/pulumi-comment.test.sh`,
wired into `actions-ci.yml` with `pulumi-ci.yml` added to its path filter) — the
test asserts the guard expression is present and AND-combined with the input, and
covers the no-op truth table (evaluated against the *extracted* expression, so a
weakened guard fails the truth table too — not just a local reimplementation).
Also wired the pre-existing `scripts/ci-gate/hold.test.sh` (ADR 0012 / #51, the
DO NOT MERGE hold pin) into `actions-ci.yml` — it existed but was never executed
in CI, so that regression pin was giving zero coverage. Not sensitive-class; no ADR.

# Reusable-workflow versioning: pin callers to `@v1`, not `@main` (ADR 0014) — 2026-07-20

Closes the `@main` blast-radius risk flagged in ADR 0010 (#31 item 5). Establishes
SemVer for the `.github` repo as a whole with a **moving major tag `v1`** plus
immutable `v1.0.0`; consumers pin `uses: …/<lane>.yml@v1` so a push to `main` no
longer redefines every repo's CI at once, and Renovate opens per-repo `@v1 → @v2`
PRs on a major. Adds `docs/reusable-workflow-versioning.md` (scheme, how to pin, how
to cut a release) and `.github/workflows/tag-major.yml` — a **human-triggered**
(`on: release: published`, `contents: write`, vX.Y.Z shape-gated) job that
force-updates `vX` to the released commit; nothing mutates tags on a plain push.
Recommendation is moving-major `@v1` as the org default, exact/digest pin as opt-in
hardening (rationale table in ADR 0014). Deferred deliberately: the one-time
`v1.0.0`/`v1` bootstrap tags (manual org action, commands documented) and flipping
existing `@main` callers (`catalog-helm`, `viager-infra`, `catalog-ui`, platform
templates) — Renovate/consumer follow-up, not this repo. ADR 0014.

# ADR 0012: merge gate honors a `DO NOT MERGE` label as a terminal hold — 2026-07-20

Fixes #51 (sensitive-class: ruleset/hold behavior). The gate merges with an
org-admin ruleset bypass; its hold opt-outs were a `hold` label, a `DO NOT MERGE`
*title* marker, and draft — but the workspace convention is "titled **or
labelled** `DO NOT MERGE`", and a PR carrying the **`DO NOT MERGE` label** matched
none of them, so a human-held PR could be auto-merged (observed during Renovate
automerge verification). Folded the label into the same terminal-hold predicate at
all four checkpoints in `ai-review-merge.yml` — the two GitHub-expression `if:`
guards (freshness, classify) gain `!contains(labels.*.name, 'DO NOT MERGE')`, and
the two bash predicates (classify- and the authoritative merge-time re-check) now
normalize label names (`ascii_upcase | gsub("[ _-]+";" ")`) so `DO NOT MERGE`,
`do-not-merge`, `Do_Not_Merge` and a case-folded title all hold. Fail-closed: the
match can only add holds. Regression-tested by extraction
(`scripts/ci-gate/hold.test.sh`, pinned to the `merge` step via `id: merge`): the
#51 label case + variants, all prior signals preserved, a green positive control,
and the non-open no-op. **This was the named blocker on the org-wide PM
autonomous-merge-authority rollout** — the gate is now the reliable guard, so that
rollout is unblocked. ADR 0012 carries the before→after diff of the sensitive
hunks.

# ADR 0011: relabel hostinger (drop `GCP`) — capability-accurate runner labels — 2026-07-19

Root-cause fix for #52, complementing the gate routing fix (#53). The `hostinger`
runner (a non-GCE Hostinger VPS, the `manish` overflow box, no ambient `gh`) was
mislabeled `[self-hosted, GCP, manish]`, so `[self-hosted, GCP]` jobs could schedule
onto it and die with `gh: command not found`. Removed `GCP` via the org runners API
(`DELETE orgs/Verjson/actions/runners/22/labels/GCP`) → now `[self-hosted, Linux,
X64, manish]`. This restores `GCP` ≡ `gce` (GCE VMs only, ambient toolchain) and
keeps hostinger a first-class option via its explicit `manish` label (already used
by `toquorum/deploy.yml`). Principle recorded: **labels describe capability, not
just provider** — a runner joins `GCP`/`gce` only if it carries the GCE toolchain.
Promotion path to rejoin general overflow = provision `gh`+git on the box (on-box,
runner-topology owner). Live API mutation (not git-revertible) → recorded as ADR
0011 with the before→after label diff + revert command; `docs/runner-routing.md`
updated (superset gotcha replaced with the restored `GCP`≡`gce` invariant + the
capability principle). #53's freshness/classify→`gate` routing stays as isolation +
belt-and-braces.

# Gate: route freshness/classify to the dedicated `gate` pool — 2026-07-19

Fix #52. The merge gate flaked with `gh: command not found` on non-`.github`
repos (first seen on verjson-helm-template#9): `freshness` (L71) and `classify`
(L181) ran on `[self-hosted, GCP]`, but `GCP` is a **superset** — the `manish`
overflow runner `hostinger` also carries `GCP` (not `gce`) and runs a non-GCE
image with no ambient `gh`, so gate jobs landing there die. `ai-review` (L330) and
`ai-merge` (L662) already ran on the dedicated `[self-hosted, gate]` pool; this
makes freshness+classify match, so all four gate jobs use `gate` (GCE subset with
`gh`, excludes hostinger) for non-`.github` and `meta` for `.github`. Regression
trigger was #39 normalizing `classify` `gce`→`GCP` on the false premise that
they're aliases — corrected that claim in `docs/runner-routing.md` (added the
`GCP ⊋ gce` gotcha, the `hostinger` dual-label footnote, and the all-four-on-`gate`
routing rule). Deeper root cause (hostinger mislabeled `GCP`) flagged in #52 for
the runner-topology owner — not fixed here (re-labeling shared runners is
sensitive-class with capacity blast radius).

# ADR 0010: platform templates consume reusable workflows — 2026-07-19

Recorded the decision (`docs/decisions/0010-…`) that each platform-template
service repo consumes the matching org reusable workflow via
`uses: Verjson/.github/.github/workflows/<lane>-ci.yml@main` instead of
hand-rolling CI: helm-template→helm-ci (#40), infra-template→pulumi-ci (#46),
ui-template→ui-ci (#48); schema/api/worker adopt `setup-verjson-node` (#36) until
a generic node-ci reusable exists. `.tmpl` placeholders (`{{name}}`,
`{{nodeVersion}}`, `@{{scope}}`) carry through as reusable `with:` inputs; each
repo's bespoke `validate.yml` is preserved and each conversion is its own PR.
Sensitive-class (centralises the CI auth surface + runner default), so recorded
durably per the verjson-cli PM's ownership ruling — the templates and reusables are
DevEx/.github's domain. Migration tracked in #49; sequencing holds infra/ui until
verjson-cli's `fix/ci-github-packages-auth` lands. Reusable `@main` pin risk noted
(→ #31 item 5). Includes the helm-template before→after diff.

# Reusable ui-ci workflow for Next.js UI repos — 2026-07-19

#31 item 3 (UI lane — completes item 3 alongside helm-ci #40 and pulumi-ci #46).
Added `.github/workflows/ui-ci.yml` (`workflow_call`), lifted from the canonical
verjson-ui-template shape (schema submodule → `npm ci` → test → `next build` with
an AUTH_SECRET placeholder). One `build-test` job: optional schema-submodule
install (`schema-dir`), root install, optional `lint`/`typecheck`, `test`, and
`build`; each optional step gated on its command input being non-empty. Node +
@verjson registry from the setup-verjson-node composite (#36, dogfooded);
`submodules-token` (fallback GITHUB_TOKEN) for private sibling submodules; `runner`
defaults to the GCP self-hosted pool. Caller commands passed via `env:` + `eval`
(injection-safe), `set -euo pipefail`. AUTH_SECRET / NEXT_TELEMETRY_DISABLED set as
build placeholders. DB/Prisma-heavy repos (e.g. toquorum) keep their bespoke
workflow — reusable-caller rule is to preserve bespoke steps.

# Reusable pulumi-ci workflow for Pulumi TS infra repos — 2026-07-19

#31 item 3 (IaC lane). Added `.github/workflows/pulumi-ci.yml` (`workflow_call`),
lifted from viager-infra's preview.yml so infra repos stop reinventing the
credential-gating dance. One job, two gates: (1) always-run credential-free
validation (`npm ci` + caller `validate-command`, default `npm run build`) — the
meaningful gate on forks / secret-less repos; (2) live `pulumi preview` (command
configurable) gated on `HAS_CLOUD_CREDS` (GCP_WIP **and** PULUMI_ACCESS_TOKEN
present) via google-github-actions/auth WIP, else a `::notice` skip (not a
failure). Node + @verjson registry come from the setup-verjson-node composite
(#36, dogfooded); `stacks` drives the matrix; `runner` defaults to the GCP
self-hosted pool (one-file fleet move), overridable to ubuntu. Secrets all
optional. IaC default is Pulumi TS, not Terraform — no terraform lane. Declarative
(no bash branching), so no extract-test, matching helm-ci.yml.

# Gate files follow-up issues for non-blocking findings — 2026-07-18

Q1a of the review-output enhancement (ADR 0009). The verdict schema gains a
`followups` array (`{location, note}`); the prompt directs the reviewer to put
**substantive** non-blocking findings there and keep pure style nitpicks out
(summary only). On a PR that is **approved and actually merges**, the `ai-merge`
job files one `ai-review-followup`-labelled tracking issue per follow-up in the
PR's repo, linking back — so substantive findings on merged PRs don't evaporate
in a comment. Filed once (checks state==MERGED, per-finding content-hash marker dedup so a
partial-failure re-run re-files only the missing findings); nothing for
still-open / fast-lane / finding-free PRs; the AI
only opens, never triages/closes (humans own the backlog). Verdict is plumbed
`ai-review` → `ai-merge` via a job output; the comment renders a `Follow-ups`
block. Committed extract-tests: `review-comment.test.sh` (+followups render +
verdict emission) and new `followup-issues.test.sh` (merged-only gating, dedup,
one-per-finding, empty/absent no-op), both wired into `actions-ci.yml`. Nitpicks
→ standards → linter is the longer arc (#43). ADR 0009.

# Gate review: pinpoint the hunks to eyeball first — 2026-07-18

Operationalized ADR 0007's pinpointing clause in the merge gate's review output.
The review verdict schema gains a `review_first` array (`{location, why}`); the
prompt instructs the reviewer to list the highest-blast-radius file:line hunks a
human should eyeball first — **mandatory** (non-empty) when the diff touches a
sensitive area (authn/authz, RBAC/ABAC, secrets, IAM/OIDC, migrations, money,
CI/rulesets), even when the verdict is approve. The gate comment now renders a
`👀 Review these first` block so a human's eye lands on the exact lines. Refactored
the submit step to be env-driven (`HEAD_SHA`/`MODEL` instead of inline `${{ }}`)
so it's extract-testable; added `scripts/ci-gate/review-comment.test.sh` (5 cases:
approve+pinpoint, empty pinpoint omitted, blocking renders pinpoint+findings,
own-PR comment fallback, no-verdict fail-closed) wired into `actions-ci.yml`.
Operationalizes ADR 0007 (no new ADR). Q2 of the review-output enhancement;
Q1a (open follow-up issues for substantive non-blocking findings) is next.

# Merge gate auto-updates stale branches — 2026-07-18

Added a `freshness` job at the head of `ai-review-merge.yml`, upstream of
`classify`: a PR whose branch is behind its base (detected via the **compare
API** `.behind_by`, which is protection-independent — `mergeStateStatus` only
says BEHIND under a strict up-to-date rule, which this org's ruleset is not, so
#40 sat behind and had to be updated by hand) gets `update-branch`d, and the
resulting synchronize starts a fresh run against the current base so green means
green against current base; a conflicting PR is held fail-closed with a single
marker-guarded comment before any model spend; Renovate PRs are left to
Renovate's own rebase cadence. Decision recorded as ADR 0008 (not sensitive-class
— update-branch is git-revertible, no auth/ruleset/secret surface). Freshness
logic (Renovate anchored-match skip / conflict hold + dedup / compare-behind
update / clean proceed / fail-open on read error) is covered by a committed test
(`scripts/ci-gate/freshness.test.sh`, 9 cases) that extracts the exact `run:`
block from the workflow — single source of truth, no drift — and runs it against
a stubbed `gh`, wired into `actions-ci.yml` so it gates gate changes in CI.
Independent pre-push review folded in (compare-based detection was its key
should-fix); the gate's own review then required this committed test — added it +
hardened the conflict-comment dedup against transient read failures. Issue #41.

# Reusable `helm-ci` workflow — 2026-07-18

Added `.github/workflows/helm-ci.yml` — a reusable Helm chart CI lifted from
catalog-helm's `ci.yml`: `helm lint` (default + caller-supplied values files),
`helm template` render (release-name defaults to the repo name), and kubeconform
validation, runner pinned once to the GCP pool. Parameterized via
`chart-path`/`release-name`/`helm-version`/`lint-values`/`template-values`/
`kubeconform-args`/`runner`. kind smoke tests are deliberately excluded — they're
bespoke per chart (dependency stubs/preflight) and stay in each repo's own
`[self-hosted, docker]` job (per the caller-migration lesson + runner-routing
doc). Bash loops (values-list splitting, basename strip, release default) unit-
verified with a stubbed `helm`. catalog-helm adopts it in a follow-up caller PR.
Issue #31 item 3 (helm). docker stack: viager-app proves docker CI is bespoke —
the setup duplication is already retired by `setup-verjson-node`; terraform/UI
reusables pending source-repo study.

# Runner routing doc + `gce`→`GCP` normalization — 2026-07-18

Added `docs/runner-routing.md` — the operational reference for `runs-on`
selection that ADR 0003 lacked: the label taxonomy (`GCP` canonical general
pool, `gce` its legacy alias on the same dual-labeled runners, `gate` the gate
subset, `meta` the `.github` self-gate lane, `docker` = `gha-docker-1` the only
Docker-socket runner, `manish` overflow, GitHub-hosted last-resort), routing
rules per job class, and the three self-hosted constraints that bit us in
`verjson-cli-cloud#59` (no ambient Node, shared persistent `~/.gitconfig`, and
`meta` can't resolve private composite actions). Normalized this repo's own
gate `classify` job `gce`→`GCP` (same physical runners, pure consistency).
Remaining `gce` `runs-on` users (verjson-cli/authz/AiB) reconcile in their own
repos. Issue #31 item 4. Follow-up (independent-review fixups): corrected the
meta private-action citation to point at the `ai-review-merge.yml` NOTE (not
`ci-telemetry.md`, which covers the separate endpoint-dormancy reason) and
footnoted that `gha-docker-1`'s group membership post-dates ADR 0003.

# Composite `setup-verjson-node` action — 2026-07-18

Added `.github/actions/setup-verjson-node/` — a composite action that does the
verJSON Node-on-self-hosted setup once: `actions/setup-node` (no ambient-Node
reliance), `@verjson` registry auth, and an **idempotent** ssh→https `insteadOf`
rewrite (`--unset-all`/`--add`) that survives the persistent runner's shared
`~/.gitconfig`. Retires the copy-pasted per-repo credential dance and both
portability gaps in `verjson-cli-cloud#59`. Tokens (`NODE_AUTH_TOKEN` + optional
git token for private git deps) are wired without persisting the secret to the
on-disk gitconfig — the credential helper reads it from the job env at clone
time. The `#59` idempotency + secret-hygiene logic is split into
`configure-git.sh` and covered by `configure-git.test.sh` (plain bash, no test
dep), run in CI by the new `actions-ci.yml` workflow (GCP pool). Consumed by
bespoke-CI repos (viager-app, cli-cloud) in follow-up PRs; the `node-ci`/
`-release` reusable workflows already cover the plain-library case. Issue #31
item 1. `@main` ref for now (retagged with item 5's pin).

# PR template: Verification + blast-radius block — 2026-07-18

Added "Verification" (evidence / not-verified) and "Blast radius & what to check
first" sections to `.github/PULL_REQUEST_TEMPLATE.md`, including a sensitive-class
checkbox that requires pinpointing the `file:line` a human must eyeball.
Operationalizes ADR 0007's pinpointing clause so verification cost scales with
blast radius on every PR.

# ADR 0007: adaptive verification by blast radius — 2026-07-18

Recorded the decision to scale human review to blast radius rather than
uniformly: reversible/low-risk categories auto-merge unattended; sensitive/
irreversible classes (auth, migrations, secrets, IAM, rulesets, destructive) are
**always** human-gated and the AI must pinpoint the exact file(s):line(s) to
eyeball; error-rise escalation is a human-configured circuit breaker; a **5%
canary** of auto-merge categories stays human-reviewed so the error signal
survives; fail toward more review on low signal. Extends/partially supersedes
ADR 0006. Tracking #33. `docs/decisions/0007-adaptive-verification-blast-radius/`.

# ADR 0006: AI-work rework telemetry (observe-and-report) — 2026-07-18

Recorded the decision to build rework telemetry that calibrates human
verification of AI work as **observe-and-report only** — it measures rework by
change-category/AI-authorship and surfaces it, but never mutates merge or
verification gates; a human holds the dial. Guards conflict-of-interest and
Goodhart by construction. Tracking: #33; schema upstream in
verjson-observability#49. Governance ADR at
`docs/decisions/0006-ai-rework-telemetry-observe-and-report/`.
# Decision log: issues vs ADRs process — 2026-07-18

Added a "When to write an ADR (vs a GitHub issue)" section to
`docs/decisions/README.md` so the team has a written convention for which
mechanism to use: issues track transient *work*, ADRs record durable
*decisions*; issue is the front door, promote to an ADR only for
architecturally-significant / hard-to-reverse (and all sensitive-class)
decisions; wire both ways; supersede rather than edit to reverse.

# AI review cost optimization

## Merge-gate CI telemetry via observability action — 2026-07-15

Rewrote the #20 telemetry (ADR 0004): replaced the custom `curl` →
`CI_TELEMETRY_ENDPOINT` export with `uses: Verjson/verjson-observability@v0.7.2`
(kept `parse-claude-execution.sh`, dropped `export-payload.sh`), reshaped to the
real `CiTelemetryPayload` schema, and made every telemetry step
`continue-on-error` so it can never break the gate. Enabled the observability
repo's Actions `access_level: organization` so the action resolves.
**Dormant** until `OTEL_EXPORTER_OTLP_ENDPOINT` (+ `..._HEADERS`) is provisioned
— the action no-ops without an endpoint. `actionlint` clean.

## Reusable Node CI/release workflows — 2026-07-15

Added `node-ci.yml` and `node-release.yml` reusable workflows to this repo,
runner pinned once to `[self-hosted, GCP]` (overridable via `runner` input;
`node-version`/`scope` inputs cover per-repo variance). Callers become 4-line
`uses: Verjson/.github/.github/workflows/node-{ci,release}.yml@main` + `secrets:
inherit`. `actionlint` clean. Next: convert the Node libs (`verjson-pg`,
`-payments`, `-upload`, `-observability`, `-oidc-claims-middleware`,
`-eslint-config`, `-graphql-conventions`) to callers — this is how those repos
get off `ubuntu-latest`, one PR each.

## Merge gate — escalate on budget exhaustion — 2026-07-15

A healthy PR (`github-runner-docker-compose#3`) was hard-failed when the Haiku
review hit `--max-budget-usd 0.15` at $0.16 on turn 11 and returned no verdict.
Fixed structurally (ADR 0002) rather than by raising the cap:

- Review step is now `continue-on-error`; an empty verdict escalates to a fresh
  `claude-sonnet-5` pass at $1.00 (runs only when the first pass produced
  nothing, so the cheap path is unchanged).
- If both passes fail: label `ai-review-inconclusive`, comment, hold the PR
  (fail-closed preserved — never auto-merges unreviewed).
- Cut agentic wandering: `--max-turns 24 → 15` + an economy prompt instruction.
- `actionlint` clean. See `docs/decisions/0002-ai-review-graceful-budget-escalation/`.

## Runner governance — reusable workflows — 2026-07-15

Goal: keep every Verjson repo off GitHub-hosted runners, standardised on the
GCP self-hosted pool (or `manish`), with GitHub-hosted reserved as last resort.

Done:

- Added a `GCP` label to the 8 GCE self-hosted runners (org Actions API).
- **Runner-group reorg (ADR 0003):** created `GCP` group (id 4, visibility all),
  moved the 8 GCE runners + `meta` into it, renamed `Default` → `GitHub`
  (id 1, now 0 runners = last resort), added a `manish` label to the `hostinger`
  runner. `GitHub` stays `default: true`, so new self-hosted runners auto-land
  there and must be moved to `GCP` after registration.
- New reusable workflow `notify-umbrella.yml` in this repo. Runner defaults to
  `[self-hosted, GCP]`; callers invoke
  `Verjson/.github/.github/workflows/notify-umbrella.yml@main`. Replaces the
  copy-pasted `notify-umbrella.yml` in the 8 submodule leaf repos
  (`catalog-api/ui/infra/helm/docs` → `Verjson/catalog`;
  `viager-app/docs/infra` → `Verjson/viager`). `actionlint` clean.

Next actions (all pending owner go-ahead — org-wide CI blast radius):

1. Convert the 8 leaf repos' `notify-umbrella.yml` to thin callers of the
   reusable workflow (one PR per repo, merge on green).
2. Migrate the repos still running real CI on `ubuntu-latest` onto
   `[self-hosted, GCP]`: `toquorum`, `catalog[-api/ui/infra/helm/docs]`,
   `viager[-app/docs/infra]`, `verjson-observability`,
   `verjson-oidc-claims-middleware`, `verjson-eslint-config`, `verjson-infra`,
   `verjson-pg`, `verjson-graphql-conventions`, `verjson-payments`,
   `verjson-upload`, `demo-repository`, `micro-one`. Fix
   `verjson-infra-template/ci.yml.tmpl` (seeds new repos).

**Out of scope — parked:** the `scrm-*` and `scv-*` repo families are parked
for the foreseeable future (owner directive, 2026-07-15). Do NOT migrate them,
and ignore their env-labelled deploy workflows (`dev`/`test`/`stage`/`prod`).
4. Optional guardrail: org ruleset requiring a check that fails any PR
   reintroducing a GitHub-hosted `runs-on`.

## Handoff — 2026-07-14

Current state:

- The cost-optimization work is merged to remote `main` through
  `Verjson/.github#17` (`b3b0935`), including the self-authored-review fallback,
  $0.50 Sonnet cap, and root-`NEXT.md` docs lane.
- `Verjson/verjson-observability#24` was re-run through this gate after the
  repair, took the docs fast lane, and merged successfully.
- `actionlint`, Prettier, and Git whitespace checks passed for the gate changes.

Next actions:

1. Exercise the self-authored fallback on a non-docs, non-sensitive test PR and
   confirm the approved-verdict comment, successful `ai-review`, and admin merge.
2. Finish the observability-side dependency tracked in
   `verjson-observability/NEXT.md`: shared emitter/contract, bounded metrics,
   one-shot OTLP export, and CI dashboard. This repo now emits bounded JSON
   payloads plus a best-effort HTTP export hook, but still depends on
   `verjson-observability` for the collector-facing implementation.
3. After production telemetry exists, use the planned 2–4 week sample to tune
   Sonnet routing and review budgets.

Do not touch:

- `.tokensave/` is untracked user data.
- The closed local branches `agent/fix-self-authored-ai-review` and
  `agent/add-observability-ci-telemetry-next` are historical; start new work
  from current `origin/main`.

This checklist tracks the July 2026 review of the organization-wide AI merge
gate. Baseline from 13 paid runs: **$2.327 total / $0.179 average**; Haiku
averaged $0.113 and Sonnet averaged $0.236.

## Completed in `optimize/ai-review-costs`

- [x] Consolidate major Renovate guidance into the mandatory merge gate.
- [x] Convert the separately required advisory workflow into a zero-cost
      compatibility shim, eliminating duplicate LLM utilization.
- [x] Reduce the maximum agent loop from 60 turns to 24.
- [x] Add hard per-run budgets: $0.15 for Haiku and $0.50 for Sonnet.
- [x] Prepare PR metadata and diff once rather than paying the model to fetch
      them repeatedly.
- [x] Use structured model output and deterministic shell review submission,
      removing the observed GitHub-tool permission denials.
- [x] Reduce checkout history from full history to two commits.
- [x] Add a 30-second synchronization debounce and verify the head SHA before
      invoking the model.
- [x] Add a deterministic documentation/community-health fast lane.
- [x] Include root `NEXT.md` planning documents in the deterministic docs lane.
- [x] Enforce the documented manifest/lockfile allowlist for non-major
      Renovate fast-lane changes.
- [x] Give major dependency updates targeted review instructions in their one
      mandatory model review.
- [x] Embed head SHA and model metadata in each submitted review for auditing.
- [x] Handle self-authored PRs: when the configured org-admin token cannot
      approve its own PR, leave an audited approved-verdict comment and let the
      required gate check plus admin merge job enforce the decision.
- [x] Validate both workflows with `actionlint`, Prettier, and Git whitespace
      checks.

## Follow-up after publishing the merged commit

- [x] Remove `.github/workflows/renovate-ai-review.yml` from organization
      ruleset `main-protection` (ID `18098028`) after the consolidated gate
      reached the remote default branch.
- [x] Delete the compatibility workflow after the ruleset change propagated.
- [ ] Collect two to four weeks of cost, turn, model, diff-size, verdict, and
      rerun data. The action already logs cost and turn totals; export them into a
      durable dashboard before changing routing based on anecdotal samples.
- [ ] Use the collected data to narrow Sonnet routing. In particular, evaluate
      routine `.github/` files and trusted action-version bumps separately from
      executable workflow or security-policy changes.
- [ ] Evaluate cached-head and incremental-diff reviews after telemetry exists.
      Retain full review for force-pushes and sensitive paths.

## Guardrails

- CI remains mandatory before every model invocation and merge.
- Sensitive changes continue to use Sonnet.
- Missing credentials, invalid structured output, budget exhaustion, red CI,
  and blocking findings all fail closed.
- Fast lanes remain deterministic and leave an auditable PR comment.
