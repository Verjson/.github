---
date: 2026-09-14
id: 20260914T074500Z
title: Derive the container-deployment contract verdict from the diagnostics it reports
impact: patch
---

`scripts/gen-container-deployment.sh contract-test` stated the nine
`container-deployment.json` preconditions twice: once as a `jq -e` predicate that decided
the verdict, and once as a `jq` program that reported which field failed. A condition
added to the predicate but not to the report would have made `join("; ")` return the empty
string, and the adopter would have seen `container-deployment contract FAILED: ` with
nothing after it — the zero-diagnostics failure the reporting was added to remove.

The generated script now states each precondition once. The report is the verdict: the
config is accepted iff the program names no violation, so a condition cannot be enforced
without also being diagnosed. `contract_fail` additionally substitutes a named reason if
any call site ever supplies a blank one, so no failure path can print a bare `FAILED:`.

Two rejections that the duplicated form handled only by accident are now explicit. An
empty or input-less config file yields no `jq` result at all rather than an empty
violation list, so the program runs under `-e` and that case stays a rejection with a
named reason; previously it was rejected by the predicate and reported with an empty
one. The accept/reject partition is otherwise unchanged, verified by running the previous
and current generated scripts against the same 53 configs — every valid shape, each of the
nine conditions violated alone, non-object and non-JSON configs, and a missing config —
and requiring identical exit status on every one.

`scripts/container-deployment-contract.test.sh` pins the properties rather than the
wording: each of the nine conditions must be stated exactly once in the generated script,
each must reject on its own while naming itself, no rejection may carry an empty reason,
and `contract_fail` must refuse to emit one. It also now reaches the assertions that sat
behind the artifact digest pins and so had never executed — the adapter checks, via a
config naming a missing and then a symlinked adapter, and the caller-workflow checks, by
re-pinning the caller digest to a mutated caller exactly as regenerating against such a
caller would.

No assertion was relaxed. This repository owns no generated copy of these artifacts;
consumer repositories pick the change up on their next regeneration at a contract ref
containing it.
