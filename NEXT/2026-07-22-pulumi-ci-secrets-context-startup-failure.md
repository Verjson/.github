# pulumi-ci reusable failed to start — `secrets` in a job-level `env:` — 2026-07-22

The `pulumi-ci.yml` reusable workflow computed `HAS_CLOUD_CREDS` in a **job-level
`env:`** from `secrets.gcp-wip` / `secrets.pulumi-access-token`. `secrets` is not an
allowed context in a job `env:` (only `github`/`needs`/`strategy`/`matrix`/`vars`/
`inputs` are), so the workflow failed to parse and every caller got a
`startup_failure` with **zero jobs** — no compile gate, no preview. Surfaced as
`tequityapp/tequity-infra` `main` red on push (it is the only pulumi consumer, so it
was the only repo affected); the reusable-CI migration's other callers use
`node-ci.yml` and were unaffected. Fix: compute the live-vs-credential-free decision
in a first `Detect cloud credentials` step (secrets ARE valid in a step `env:`) and
expose it as `steps.creds.outputs.has_cloud`; the auth / `pulumi` / skip-note steps
now gate on that output. Behaviour is unchanged — live preview still runs only when
both GCP WIP and the Pulumi token are present, credential-free validation runs alone
otherwise. Reported from tequity's platform survey.
