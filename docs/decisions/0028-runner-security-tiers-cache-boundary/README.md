# 0028 — CI security tiers and runner-aware npm cache boundaries

- **Date:** 2026-07-28
- **Issue:** Verjson/.github#166
- **Category:** runner topology / reusable-workflow security posture
- **Supersedes in part:** ADR 0003's `GCP visibility: all` and public-repository access decision

## Context

ADR 0003 deliberately made the persistent GCP runner group visible to every
repository, including public repositories, to avoid breaking consumers during
the initial migration. It also treated GitHub-hosted capacity as a last resort.
That availability-first posture does not distinguish trusted private code from
fork/public code that must not execute on a reused self-hosted filesystem.

The cache default added by #152 exposed a second persistent-runner boundary:
`actions/setup-node` archived the runner's accumulated global npm cache. In
`Verjson/toquorum` run `30363686973`, the archive was approximately 4.1 GB.
Useful checks took 5–10 minutes, while post-job cache handling occupied each
runner for another 17–27 minutes and contributed to a 56-minute queue.

## Decision

1. Classify CI into three governed tiers:
   - **isolated** for public repositories, fork PRs, and other untrusted or
     sensitive validation. Use a fixed GitHub-hosted image until
     `Verjson/verjson-github-runner#33` proves one fresh job container and
     writable layer per ephemeral job;
   - **trusted** for same-repository work in selected private repositories on
     the persistent GCP pool;
   - **fast** as a trusted execution shape that consolidates setup and validation
     to reduce runner assignments, not as a weaker authorization boundary.
2. Change reusable Node CI, release, and setup defaults so GitHub Actions npm
   cache transfer is off on persistent runners. An explicitly enabled cache is
   scoped to `runner.temp`, never the accumulated global npm cache.
3. Reusable workflows report enabled cache size and clear content exceeding the
   caller-configurable limit (1024 MB default) before setup-node's post step.
4. Runner-group access, not labels, is the authorization boundary. The GCP group
   must move from all-repository/public access to selected trusted repositories.
   A public repository cannot regain persistent-runner access without a new
   reviewed exception that restricts exact trusted workflows.
5. Third-party actions and reusable workflow dependencies remain immutable.
   PR jobs receive explicit least privilege and no release credentials.

## Consequences

- Persistent runners retain their local content-addressed npm cache without
  transferring cross-repository state through Actions.
- Cold/isolated runners may opt into bounded remote caching where measurements
  show a net benefit.
- Public and fork validation may consume GitHub-hosted minutes until the
  ephemeral contract is independently proven; isolation takes precedence over
  the former “hosted last resort” preference.
- Restricting the live group requires an inventory of current GCP consumers and
  a before/after authorization receipt. Repositories omitted from that inventory
  will queue rather than silently fall back to a broader runner.
- The ephemeral implementation and destructive lifecycle tests remain tracked
  by `Verjson/verjson-github-runner#33`; documentation does not claim that the
  current `RUNNER_EPHEMERAL` flag already supplies fresh-container isolation.

## Sensitive-hunk summary

```diff
- GCP: visibility all, public repositories allowed
+ GCP: selected trusted repositories, public repositories denied

- cache default: true; setup-node may archive persistent ~/.npm
+ cache default: false; opt-in path is runner.temp and bounded
```
