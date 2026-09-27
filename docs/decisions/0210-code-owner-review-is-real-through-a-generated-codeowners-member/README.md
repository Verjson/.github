# 0210 — Code-owner review is real: the generated CODEOWNERS is a required member of the adopter contract

- **Date:** 2026-09-27
- **Status:** Accepted
- **Issue:** [Verjson/.github#1272](https://github.com/Verjson/.github/issues/1272)
- **Related:** [ADR 0191](../0191-contract-releases-are-the-unit-of-adoption/README.md), [ADR 0202](../0202-bind-autonomous-merge-to-independent-review-receipt/README.md), verjson-ci#223
- **Category:** organization ruleset behavior (sensitive class)

## Context

Organization ruleset `main-protection` (id 18098028, `enforcement: active`, targets
`~ALL` repositories on the default branch) carries `require_code_owner_review: true`
in its pull-request rule. A code-owner requirement matches nothing in a repository
without a `CODEOWNERS` file. On 2026-09-10 the sweep for #1272 found a `CODEOWNERS`
in 3 of 101 repositories, so in ~98 the rule was enforced in the ruleset while asking
for nothing. Nothing about that is exploitable; the defect is that the rule's
recorded intent and its effect disagree, and the audit cannot tell an intentional
exemption from an oversight.

Two things changed between the finding and this decision:

- `scripts/gen-changelog-caller.sh codeowners <sha>` (rendering `scripts/codeowners.py`)
  already exists and emits one canonical file: `* @Verjson/devs`, with a header
  naming the generator. The `@Verjson/devs` team holds `push` on the managed
  repositories (granted 2026-09-23, recorded on #1272).
- `Verjson/verjson-ci` adopted that generated file in PR #223 (merged 2026-09-26
  13:19 UTC) after verjson-ci#212 cleared the `package.json` surface it had to
  wait for. The adoption path is proven on a real repository.

The alternatives were to make the rule real everywhere or to drop it from
`main-protection`.

## Decision

Keep `require_code_owner_review: true` in `main-protection` and make it real by
making `.github/CODEOWNERS` a **required member of the generated adopter set**,
verified by the generated contract test every adopter already runs on each pull
request:

- The canonical bytes live in `config/codeowners/CODEOWNERS` (the reviewed source)
  and are embedded verbatim in `scripts/gen-changelog-caller.sh`, which is itself the
  pinned artifact: the `codeowners` mode emits them and the `contract-test` mode
  embeds `EXPECTED_CODEOWNERS_SHA256`, their digest, without resolving anything at
  generation time. That matters because the required-checks audit materializes only
  the generator at a pin — no checkout, no network, and a deliberately hostile
  interpreter environment — and must still emit the same contract test; the audit's
  own byte comparison covers the five members it already regenerates and does not
  yet compare `.github/CODEOWNERS`, which is a follow-up rather than a dependency.
  `scripts/codeowners.py` reads the same source file, and `scripts/codeowners_test.py`
  fails if the generator's embedded copy drifts from it.
- The generated suite fails closed when `.github/CODEOWNERS` is absent, is reached
  through a symlink (either the directory or the file), does not match the pinned
  digest, or is shadowed by a competing `CODEOWNERS` or `docs/CODEOWNERS`, which
  GitHub would read in preference. The absent and drifted failures name the
  regeneration command; the shadowing failure names the file to remove.
- The meta-suite (`scripts/ci-gate/changelog-caller-contract.test.sh`) builds every
  adopter fixture with the generated file and asserts all four rejections with the
  existing no-op-mutation guard, so none of the cases can be vacuous.
- `docs/changelog/README.md` lists `codeowners` in both adoption command lists.
  `docs/changelog/migration.md` and the adoption-issue template
  (`scripts/render-changelog-adoption-issue.py`) are executable against the
  *recommended* contract pin, which predates this change and has no `codeowners`
  mode, so they gain the step in the same PR that advances the recommended pin.
  `scripts/changelog-migration.test.sh` runs the generated contract test at that pin
  and fails closed until the step is added; the adoption-issue test only asserts the
  rendered block's artifacts exist, so that PR must also add `.github/CODEOWNERS` to
  its `ARTIFACTS` list.

Fleet rollout follows [ADR 0191](../0191-contract-releases-are-the-unit-of-adoption/README.md):
an adopter that regenerates at a contract SHA containing this change must generate
the CODEOWNERS member in the same pass, exactly as it must regenerate any other
member. Repositories pinned before this SHA are unaffected until they advance,
which is the release train under #1374; the managed set (`verjson-ci`,
`verjson-compliance`, `verjson-compliance-schema`, `verjson-agents`) leads.

## Why not drop the rule

Dropping `require_code_owner_review` would have been honest about the present, but
it discards a control the organization had already started adopting on merit, and it
weakens the human-path merge on every repository to satisfy an audit. The rule costs
the autonomous path nothing: the merge Apps and organization admins are `always`
bypass actors on `main-protection`, so the independent-review receipt
(ADR 0202) remains the control for autonomous merges, while a human-initiated merge
now requires a reviewer from the team that actually owns the code. A rule that is
real in 3 repositories and a template nobody enforces would recreate #1272 on the
next sweep; the contract test is the enforcement that makes the template stick.

## Why the contract test, not a separate conformance job

The generated contract test is already the single conformance surface every adopter
runs before merge, it is already digest-pinned to one contract SHA, and its
generator already owns the file. A second job would add a workflow to ~95
repositories to check one file that the existing job can check with fifteen lines.
The fleet sweep (`changelog-contract-fleet-report.yml`) surfaces the same failure
across repositories without further code.

## Consequences

- Every adopter regenerating at or after this SHA gains `.github/CODEOWNERS`
  (`* @Verjson/devs`); a repository that needs a different ownership map must change
  the reviewed source `config/codeowners/CODEOWNERS` and the generator's embedded copy
  upstream rather than hand-edit the file, since the digest refuses a local edit.
- `@Verjson/devs` must hold write access wherever the file lands; a repository where
  the team lacks it makes the rule impossible to satisfy on the human path and must
  be granted before its regeneration, as was done for the managed set on 2026-09-23.
- The coarse `#1272 blocked by verjson-ci#143` edge was dropped on 2026-09-26: the
  epic was never the prerequisite, verjson-ci#212 was, and it has merged.
- If `main-protection` ever drops `require_code_owner_review`, this member becomes
  advisory and a successor ADR should demote it to `optional`.
