# GitLab CI migration plan

This runbook turns [ADR 0161](decisions/0161-migrate-ci-to-gitlab-with-measured-parity/README.md)
into bounded delivery work. It assumes GitLab CE and colocated runner capacity already
exist. It does not authorize provisioning, secret writes, live check changes, or spend.

## Outcome

Move economically justified CI execution from GitHub Actions to GitLab while GitHub
remains the pull-request and required-check authority during transition. Preserve exact
head binding, trust lanes, failure semantics, and a tested GitHub fallback. Reduce paid
GitHub Actions usage to the approved floor; pursue zero only where total cost and security
evidence support it.

## Inventory before implementation

Create one versioned row per logical workload, not per YAML file:

| Field | Required evidence |
| --- | --- |
| Identity | repository, workflow/job, triggers, required-check name, owning team |
| Work | command contract, toolchain/image, timeout, services, expected outputs |
| Trust | untrusted, trusted, or privileged; code provenance; runner isolation |
| Credentials | secret name by role (never value), issuer/audience, scope, protected-ref rule, revocation owner |
| Provider coupling | GitHub APIs/Apps/Packages/environments, Actions cache/artifacts, OIDC, reusable-workflow semantics |
| Cost | billed minutes and rate, self-hosted allocation, retry rate, storage/egress, operator effort |
| Reliability | queue time, duration, terminal-result rate, flakes/retries over the same baseline window |
| Migration state | retained on GitHub, shadowing, canary-required, GitLab-default, or retired |

The repository snapshot on 2026-09-01 contains 47 workflow files and demonstrates every
coupling category above. That count is discovery evidence only; rerun the inventory at
each phase boundary and classify the commands inside the workflows.

## Phases

### 0. Baseline and select the canary

1. Export at least four representative weeks of GitHub usage, queue, duration, retry,
   and conclusion data, split by repository visibility and runner/OS class.
2. Record current branch rules and exact required-check names. Identify checks whose
   authority comes from GitHub Apps or reusable-workflow outputs.
3. Map every credential and provider API dependency. Treat an unknown as privileged and
   retain it on GitHub.
4. Select one frequent, credentialless Linux workload with deterministic results and no
   release, deploy, merge, or organization-admin authority.
5. Define the observation window and numeric reliability, latency, and total-cost gates
   before seeing the candidate result.

Exit: reviewed inventory, reproducible baseline, canary owner, thresholds, and tested
GitHub-only route. No production setting changes.

### 1. Extract a portable workload contract

Make the canary's commands runnable locally and from either provider with the same pinned
toolchain, lockfiles, environment contract, timeout, and output schema. Keep provider
adapters responsible only for checkout, cache transport, receipt publication, and status
reporting. Mock external services in unit tests; integration fixtures must be isolated and
disposable.

Exit: both adapters run the same contract against a fixed revision and negative fixtures
prove failure, timeout, cancellation, and no-op/deferred mappings.

### 2. Shadow dual-run

Mirror an immutable commit to GitLab and run the canary without making GitLab authoritative.
Record mirror arrival time and reject a pipeline whose project or SHA differs from the
GitHub event. Compare normalized receipts automatically. GitHub remains the only required
result and the fallback remains exercised.

Do not expose protected variables to merge-request or fork pipelines. Do not introduce a
GitHub status-write token into a job that executes repository code. If a status bridge is
needed for observation, isolate it after the pipeline. With a separate read-only GitLab
API credential, the bridge must fetch and verify the immutable project ID, pipeline and
job IDs, exact commit SHA and ref, terminal status, and executed CI configuration/template
digest against the digest pinned to a trusted revision. Repository-produced receipts,
names, and metadata are comparison inputs only and never authority for the GitHub check.

Negative fixtures must show that repository code cannot forge green by emitting the
reviewed job name or changing `.gitlab-ci.yml` or an included template. The bridge rejects
missing or ambiguous provider metadata and any project, pipeline, job, SHA, ref, status,
or configuration-digest mismatch.

Exit: the predetermined sample window passes all parity gates with no silent skips,
credential exposure, stale mirrors, forged status, or material total-cost regression.

### 3. Canary authority

Publish the bridge-verified GitLab result under a new check name on a bounded
repository/workload. Keep the existing GitHub check required for the first observation
interval. After readback proves both checks bind the exact head, the bridge independently
verified the trusted CI configuration, and same-named-job and modified-configuration
forgeries are rejected, make the GitLab check required in a separate reviewed change.
Retain the GitHub route as a non-required fallback; do not delete it.

Rollback immediately on incorrect SHA binding, missing terminal results, parity drift,
queue/duration breach, elevated retries, secret-boundary failure, or cost breach. Restore
the previously captured ruleset and GitHub route, then verify exact readback.

Exit: authoritative canary passes the reliability window, injected failures block merges,
rollback has succeeded, and the cost ledger projects a net saving outside dual-run.

### 4. Cut over by workload class

Expand only to workloads with the same trust and provider-coupling profile. Re-run the
inventory and parity suite for each repository; structural similarity is not evidence.
Migrate credentialless portable work first, bounded service work second, and trusted work
only after its explicit credential design is approved. Keep privileged GitHub control-plane
jobs on GitHub until separately decided.

Each cutover has one owner, one rollback switch, an expiry for dual-run, and a receipt that
identifies the last verified GitHub definition. A GitLab Runner blue/green change can roll
back to its previous verified slot. It never invokes or shares state with GitLab CE backup,
upgrade, or restore operations.

Exit: every workload in the class is GitLab-default or carries a reviewed GitHub-retained
reason; no indefinite shadow pipelines remain.

### 5. Retire avoidable GitHub execution

After the observation window, remove obsolete GitHub execution without deleting the
portable contract or rollback revision. Reconcile required checks, scheduled triggers,
caches, artifacts, tokens, and documentation. Revoke bridge credentials that no retained
job needs. Verify that protected GitHub control-plane workflows still run.

Exit: the approved GitHub Actions spending floor holds for two consecutive billing
periods, total CI cost is lower than baseline, service levels are met, retained GitHub jobs
have current rationales, and restore/rollback procedures have named owners and fresh tests.

## Cost ledger and decision rules

Use the same currency and allocation period for both providers. Attribute GitHub-hosted
minutes by OS and visibility, GitHub self-hosted compute, GitLab runner compute, incremental
GitLab CE storage/backup/egress, maintenance labor, failed/retried jobs, and temporary
dual-run. Report cost per successful workload and per merged change.

- Prioritize the largest measured avoidable paid workload, provided it is not privileged.
- Do not migrate free public Linux work merely to improve a percentage if total cost rises.
- Stop expanding a class if its projected saving does not repay migration and operating
  cost within the approved horizon.
- Never waive parity, isolation, or rollback evidence to reach zero GitHub spend.

## Required receipt for each cutover

- immutable GitHub and GitLab repository identities and commit SHA;
- workload-contract and provider-adapter revisions;
- terminal result and normalized output/artifact comparison;
- injected-failure and deferred/no-op results;
- bridge-side GitLab API readback of immutable project, pipeline, job, SHA, ref, terminal
  status, and executed configuration/template digest pinned to a trusted revision;
- rejection evidence for a forged same-named job and modified `.gitlab-ci.yml` or included
  template;
- mirror lag, queue time, duration, retry rate, and sample window;
- before/after projected total cost and billing source;
- current required-check readback and exact-head proof;
- credential scopes, protected-ref/runners evidence, and revocation owner;
- last verified GitHub fallback revision and successful rollback rehearsal; and
- explicit holds for ruleset writes, secrets, live runner registration, GitLab CE
  maintenance, infrastructure spend, releases, or deployments.

## Operational separation

GitLab CE maintenance owns database and repository consistency, backups, supported upgrade
hops, maintenance windows, health checks, and restore tests. GitLab Runner operations own
ephemeral execution, drain, admission, blue/green slot health, and rollback to a previous
runner artifact. #629 owns the DigitalOcean GitHub Actions runner fleet. They may use a
common receipt vocabulary, but they do not share controllers, credentials, state stores,
or rollback commands.
