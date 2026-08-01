---
date: 2026-08-01
issue: 244
title: node-release reports whether semantic-release actually published
---

`node-release.yml` exposed no signal for "did this run publish a version", so a consumer
could only gate follow-up work on job success — which is green on every push that
semantic-release decides needs no release. Verjson/verjson-browser-agent#17 needs to run a
one-time package deprecation exactly once, after a real publication.

The workflow now exposes two `workflow_call` outputs, `new-release-published` and
`new-release-version`, sourced from the publish step.

Getting the value required changing how semantic-release is invoked: the CLI reports the
outcome only in its log text, so the publish step now runs
`.github/release-tooling/emit-release-outputs.mjs`, which calls semantic-release's
programmatic API and writes the structured result to `$GITHUB_OUTPUT`. The supply-chain
shape is unchanged — the runner is copied out of the same `job.workflow_sha` checkout as
the lockfile and imports semantic-release from the tree `npm ci --ignore-scripts` builds,
so nothing is resolved dynamically and no dependency was added. Rejected alternatives:
`cycjimmy/semantic-release-action` (replaces the locked tooling with a third-party action
and routes around `release-tooling-audit.sh`), scraping the CLI log (couples a published
contract to log formatting), `@semantic-release/exec` (plugin config lives in each
caller's `.releaserc`, so a reusable workflow cannot guarantee it), and comparing git tags
(reports a publication on a re-run of an already-released commit — fail-open).

The runner fails closed in both directions: any thrown error, and any result shape that is
neither `false` nor an object carrying a non-empty string version, exits non-zero and
leaves the outputs unset. Because a failed or skipped job also propagates an empty value,
callers must write `== 'true'`; that is stated in the output description, in
`docs/node-workflows.md`, and asserted by a test.

`scripts/node-release-outputs.test.sh` covers the wiring and runs the runner against a
stubbed semantic-release for the published, no-op, thrown, missing-`nextRelease`,
missing-version, non-string-version, empty-version, undefined-result and
absent-`GITHUB_OUTPUT` cases; it is wired into `actions-ci.yml`.
`scripts/node-workflow-pins.test.sh` moves from asserting the CLI binary invocation to
asserting the equivalent locked-runner invariant.
