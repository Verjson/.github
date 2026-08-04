# 0052 — The changelog release push needs a credential the branch ruleset bypasses

- **Date:** 2026-08-04
- **Issue:** [Verjson/.github#389](https://github.com/Verjson/.github/issues/389)

## Context

`changelog-release.yml` finishes a release with one `--atomic` push of the
snapshot commit and its tag to the default branch. ADR 0038 recorded that
release callers "require contents-write credentials", and the 2026-08-01
amendment (#295) made the workflow express that. Both were about *permissions*.
Neither addressed *branch rules*, which are a separate gate hit at the same line.

Every Verjson repository carries a `main-protection` branch ruleset with
identical rules — `deletion`, `non_fast_forward`, `required_linear_history`,
`pull_request`, `workflows` — and identical bypass actors: `OrganizationAdmin`
and `Integration:2740` (Renovate). GitHub Actions is not among them. So the
documented and universally copied wiring, `push_token: ${{ secrets.GITHUB_TOKEN }}`,
cannot complete a release:

```
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote: - Changes must be made through a pull request.
remote: - Required workflow 'AI review + auto-merge' is not satisfied
 ! [remote rejected] v0.4.0 -> v0.4.0 (atomic transaction failed)
```

Evidence: [verjson-temporal-kit run 30923654264](https://github.com/Verjson/verjson-temporal-kit/actions/runs/30923654264),
the first release dispatched after that repository adopted the contract.

This was fleet-wide, not local. The three older adopters — `verjson-browser-agent`,
`verjson-identity-contracts`, `verjson-cli-projects` — carry byte-identical
rulesets and the identical `GITHUB_TOKEN` wiring, and none had ever landed a
`release:` commit on its default branch. The release half of ADR 0038 had never
run to completion anywhere.

Nothing in a pull request could have caught it. `changelog-contract.test.sh`
exercises `release` against a local fixture repository **with no remote**, so the
push never happens and every assertion passes while the real push is impossible.
That is the shape of #309 again: the failure lives past the last thing a pull
request can check.

## Decision

**The release caller passes an admin-scoped `push_token`, not `GITHUB_TOKEN`.**
`ORG_ADMIN_TOKEN` already exists org-wide and satisfies the `OrganizationAdmin`
bypass, matching the precedent set by `gen-privileged-merge-caller.sh` of passing
only that one secret for a privileged push.

This is verified, not assumed. `verjson-temporal-kit` re-dispatched with
`ORG_ADMIN_TOKEN` and completed: run 30924271828 succeeded, `release: v0.4.0`
landed on `main` at `3374eff2`, and tag `v0.4.0` points at it.

Three supporting changes keep the decision from decaying back into folklore:

- `docs/changelog/README.md` documents the release caller's `push_token` for the
  first time. It was never shown, which is precisely why every adopter reached
  for `GITHUB_TOKEN` by analogy with the validation caller.
- `changelog-release.yml` no longer instructs callers to pass `GITHUB_TOKEN` in
  its own comments, and states the ruleset requirement at the secret's
  declaration.
- The **generated** contract test rejects a `release.yml` whose `push_token`
  resolves to the Actions token. The rejection has to be static: the real
  failure needs a real remote carrying a real ruleset, which no fixture has. It
  therefore has to survive the ordinary ways the same wiring gets spelled — a
  quoted scalar, the `github.token` alias, case-insensitive
  `secrets.github_token`, a folded value on the next line — because a guard that
  catches only the canonical form reports green on a release that cannot run.
  `scripts/ci-gate/changelog-caller-contract.test.sh` asserts each of those
  rejections, and asserts that a correct wiring carrying a `# NOT GITHUB_TOKEN`
  comment is still accepted.

### Alternatives considered

**Add the GitHub Actions app as a ruleset bypass actor.** Narrower in privilege
than an admin PAT, but it lets *any* workflow in the repository push to the
default branch, including one introduced by a pull request. That trades a
credential held by one dispatch-only job for a hole in branch protection open to
every job in the repository — a larger blast radius in a worse direction.

**Have the release open a pull request and merge it.** This keeps branch
protection meaningful, and is the right long-term shape. It is not a
configuration change: the contract requires the tag to point at the *exact*
snapshot commit, so a squash or merge commit rewrites the object the tag must
name, and the tag would have to be created after the merge against a SHA the
release job did not produce. Deferred rather than rejected.

## Consequences

- The release job holds an admin-scoped credential, which is wider than the
  repository-scoped default and is the real cost of this decision. It is
  bounded by the job already running only on explicit dispatch, only from the
  default branch, and for at most ten minutes.
- That credential is passed as the single named secret `push_token`. `secrets:
  inherit` would hand the release job the caller's whole store for no benefit;
  nothing enforces that today, and it is recorded here as a preference rather
  than an invariant.
- The narrowing this decision does not do — a least-privilege GitHub App with
  `contents: write` and a ruleset bypass, replacing the admin PAT — remains the
  correct end state, tracked alongside the existing org-secret scoping work
  (#265, and `verjson-agents#138` for the equivalent publication token).
- Existing adopters must change `push_token` and re-pin; until they do, their
  releases keep failing safely. `--atomic` means a rejected release leaves no
  tag, no snapshot, no package and `NEXT/` untouched.
- Regenerating the contract test to gain the new assertion moves the pin, so
  adopters re-run all three generated artifacts together as usual.

## Rollback

Revert the implementing pull request. Adopters reverting to `GITHUB_TOKEN` will
find releases rejected by GH013 again; the alternative rollback is to add
GitHub Actions to the ruleset's bypass actors, which supersedes this ADR rather
than reverting it.
