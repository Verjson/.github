---
date: 2026-09-17
issue: 1369
impact: patch
title: Cover the secretless PR and trusted-ref lanes in the conformance matrix
---

The pre-publication conformance matrix now exercises both secretless lanes
against synthetic adopters: which events each lane admits, that no step in the
credentialless build job is handed `NODE_AUTH_TOKEN`, that the approved-package
allowlist is exact in both directions with per-manifest authorization, and that
a refused acquisition fails the required check instead of reporting success
having verified nothing.

The event boundary and the approved-dependency allowlist are enforced inside
`run:` scripts — one an embedded Python program — so the matrix now runs those
scripts unmodified, in a closed environment whose bindings must be exactly the
step's declared expression-valued `env:` names, over a synthetic checkout it
builds. A model that inferred their verdicts from shell layout would assert
against a paraphrase that drifts from the published contract in silence.

That sandbox withholds the developer's environment but not the runner's own
runtime: stripping `LD_LIBRARY_PATH` stopped the contract's embedded Python
from loading its shared library, and the harness now raises on a 126/127 rather
than returning it, because "could not run" and "refused" are both non-zero
exits and only one of them says anything about the contract.

Every refusal asserts the contract's own reason and is paired with the
admission it is the complement of: a bare non-zero exit is equally satisfied by
a fixture that drifted into being malformed or by a validator that refuses
every input. The refusal-propagation property was control-tested by deleting
`build-test`'s acquisition guard from an in-memory mutant, which reddens it
with `Verjson/verjson-ci#184`'s exact failure mode — a required check
concluding success on a lane that declined to do the work.

Requirements 2 and 3 of #1369; requirement 5 is held for a separate change.
