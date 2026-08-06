---
date: 2026-08-06
title: Declare the core required checks per stack, so GitHub waits instead of the gate
issue: 472
---

ADR 0058 decided the organization would declare required status checks and let GitHub wait
for them. Nothing had been declared: `main-protection` (18098028) carried no
`required_status_checks` rule at all, so every check in the org was advisory. Steps 1–5 of
that ADR are now executed, and the
[ADR is amended](docs/decisions/0058-github-waits-for-checks-not-the-gate/README.md) with
what the execution corrected.

| Ruleset | Scope | Required contexts |
| --- | --- | --- |
| `core-checks-node` (20515817) | `verjson-stack=node` ∧ `verjson-core-checks=enforced` — 18 repositories | `ci / build-test`, `ci / eligibility` |
| `core-checks-actions` (20515822) | `verjson-stack=actions` ∧ `enforced` — 2 repositories | `shell-tests` |

Both are `active`, `strict: false` (requiring branches to be up to date would serialize
every merge in the org behind a rebase), `do_not_enforce_on_create: true`, and bypass is
`OrganizationAdmin` only — the merge gate's app is deliberately not a bypass actor, or the
rule would be advisory again on the exact path the org merges through.

- **Evaluate mode was tried and is a no-op on this plan.** ADR 0058 steps 3–4 are built on
  staging the rulesets in `enforcement: evaluate`. The API *accepts* it on Team, but
  `GET /orgs/Verjson/rulesets/rule-suites` returns `403 Upgrade to GitHub Enterprise`. A
  rule staged that way blocks nothing and reports nothing, which is worse than either
  alternative because it looks like protection. The blast radius was measured directly
  instead — sweep open non-draft PRs for the contexts, classify, remediate, then activate —
  the same method ADR 0061 used a few hours earlier.
- **Stack alone cannot scope the rule.** A nonconformant repository still belongs to its
  stack, so `verjson-stack == node` would have caught `verjson-ai`, whose caller job name
  means `ci / build-test` never reports and every PR would hang pending forever. Conformance
  is carried by a second property `verjson-core-checks` (`enforced` / `exempt`) and the
  conditions are ANDed. Verified against the live API rather than assumed: `verjson-email`
  receives both contexts, `verjson-ai` receives neither.
- **Blast radius before activation:** of 25 open non-draft PRs on the 18 node repositories,
  19 already satisfied both contexts, one was in progress, and five were failing
  `ci / build-test` while remaining mergeable — which is the defect being closed. **None**
  were blocked by an absent context, so no PR is wedged by this change.
- **`gate` is not required yet, and that is the measurement's verdict, not an oversight.**
  53 of 87 open non-draft PRs across the org carry no `gate` check run at all, spread over
  roughly twenty repositories. Requiring it today would wedge each of them permanently —
  the "required but absent" failure ADR 0058 names explicitly. Their heads have not moved
  since before the `workflows` rule reached them; the remedy is a re-trigger sweep first.
- **Retiring the gate's CI poll loop (ADR 0058 step 6) is now conditional per repository.**
  67 of 91 repositories have declared no required checks. A gate that stops waiting there
  makes their CI advisory silently, which the ADR calls a worse defect than the deadlock it
  removes. Step 6 can retire the loop only where a repository has declared required checks —
  today the 18 node and 2 actions repositories — never org-wide on a single date.

`helm`, `pulumi` and `ui` get no ruleset: each stack has exactly one repository and all
three are nonconformant, so there is nothing to enforce yet. Fleet classification
(43 conformant, 4 nonconformant, 44 unrecognised CI) comes from
`scripts/classify-repo-stacks.sh`.
