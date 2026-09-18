---
date: 2026-09-18
issue: 1437
impact: patch
title: Stop attributing an empty ruleset response to an ungoverned base ref
---

`assert-mergeable-head.sh` reported every zero-length required set with one sentence —
`declares no required status checks, so a green rollup proves nothing about it` — and on a
merge gate a wrong attribution is a wrong remedy. The documented response to an ungoverned
ref is *add a ruleset*, so an operator reading that sentence would widen a ruleset that
already exists, or decide the gate does not apply to the repository and merge by hand.

Gate A now distinguishes the shapes the response can actually take, all still failing
closed with exit `3`; ADR 0184's exit-code taxonomy is deliberately untouched.

- A **populated** rule list carrying no `required_status_checks` rule is a genuinely
  ungoverned ref. The message keeps the original sentence and adds the count and types of
  the rules that *were* read, so the remedy names the ruleset that already governs the ref
  rather than implying one is missing.
- An **empty** rule list names the ambiguity instead of asserting a cause. The suspected
  cause — an organization ruleset a repository-scoped token cannot see — was tested against
  the live endpoint and does not exist: `repos/{owner}/{repo}/rules/branches/{ref}` returns
  organization-sourced rules in full, `ruleset_source_type: Organization` included, to a
  wholly unauthenticated caller, and a caller without repository read is refused
  401/403/404, which Gate A already treats as fatal. What does produce `200 []` is an
  ungoverned ref *or* a ref that does not exist under the path queried — a deleted,
  renamed, or wrongly encoded ref answers identically — and those have opposite remedies,
  so the message states both and says they are indistinguishable from the response alone.
- A body that is **not a JSON array** is named as a bad response shape, which is evidence
  about neither the ref nor its governance.

The script's header now states what read access Gate A needs and that an adopter lacking
it fails closed with a message naming the token, recording that an empty list is not that
adopter's signature. `docs/merge-gate-guidance-proposal.md`'s exit `3` bullet no longer
teaches the ungoverned-ref remedy for all three conditions.
