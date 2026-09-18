---
date: 2026-09-17
issue: 1369
title: The contract is exercised against synthetic adopters before it is published
impact: minor
---

A reusable workflow is only ever exercised by real callers, after publication,
so a contract defect reaches every adopter before anyone is positioned to see
it. `Verjson/verjson-ci#184` is the worked example: `node-ci.yml` shipped in a
state where a deferred head reported the required `ci / build-test` context
SUCCESS having executed no test, lint, type check, or repository-local contract
guard. It was green the whole time.

`scripts/ci-gate/conformance/` closes that gap at the hub. Synthetic adopters
under `adopters/` are ordinary caller workflows — the shape a real repository
commits — and the harness statically models what the contract does when each
one calls it under a given scenario: which jobs run, which steps execute, and
what conclusion each job contributes to the caller's check rollup.

Every case asserts **positive evidence of execution**, never absence of red. A
suite that only asserts "the run was green" reproduces the exact defect it
exists to prevent. Concretely:

- A deferred head must publish a rollup entry whose conclusion is outside the
  set a merge gate accepts, not merely skip its work quietly.
- A lane that runs must execute a step from a registered work-step set, and a
  separate assertion requires every registered step to still exist in the
  contract — an evidence list that silently stops matching is worse than none.
- `regressions/node-ci-pre-adr-0178.yml` is the contract as it stood when #184
  shipped, checked in as a counter-example, and the matrix asserts the deferral
  property **fails** against it. A regression test that passes against the
  defective contract proves nothing.

Two properties of the harness matter as much as the cases. It fails closed:
a guard reading a context the scenario does not bind raises, and an expression
construct the evaluator does not implement raises, rather than evaluating to
false — a model that guesses reports every guarded step as skipped and asserts
nothing while looking thorough, which is the same shape of failure again. And
input bindings are derived from the fixture callers rather than hand-written,
so removing or renaming a `workflow_call` input fails here instead of in a
hundred adopter builds. That already earned itself: `node-ci-protected.yml`
requires three inputs `node-ci.yml` does not, which is why it has its own
fixture.

Step 3 of the contract-distribution sequence in ADR 0185. The matrix covers
`node-ci.yml` and `node-ci-protected.yml`; extending it to the generated
adopter set and the remaining reusable workflows is follow-up work.

## The secretless lanes

Both secretless lanes are now covered by the same matrix: which events each one
admits, that no step in the credentialless build job is handed
`NODE_AUTH_TOKEN`, that the approved-package allowlist is exact in both
directions with per-manifest authorization, and that a refused acquisition
fails the required check instead of reporting success having verified nothing.
The two lanes admit disjoint event sets — a same-repository `pull_request` on
one, `push` and explicit `workflow_dispatch` on the other — and declaring both
at once, or neither, is refused on every event, so no combination of the two
inputs routes an untrusted head into the credentialed acquisition job. Nothing
else distinguishes them: both take the same acquisition path and execute the
same work, so the trusted-ref lane cannot become a weaker route to the same
required check.

Those rules are enforced inside `run:` scripts — one an embedded Python program
— where the static model deliberately declines to infer a verdict. So
`contract_steps.py` extracts and executes the step unmodified, in a sandbox
whose bindings must be exactly the step's declared expression-valued `env:`
names, over a synthetic checkout the test builds. A paraphrase would have been
cheaper and would drift from the published contract in silence, which is the
failure mode this matrix exists to close. Every refusal asserts the contract's
own reason and is paired with the admission it is the complement of: a bare
non-zero exit is equally satisfied by a fixture that drifted into being
malformed, or by a validator that refuses everything.

That sandbox withholds the developer's environment but not the runner's own
runtime, and the difference is not cosmetic: stripping `LD_LIBRARY_PATH`
stopped the contract's embedded Python from loading its shared library on the
runner, and seven allowlist cases failed with a loader error that the
reason-naming assertions caught and a bare exit-status assertion would have
accepted. The harness now raises on a 126 or 127 rather than returning it,
because "could not run" and "refused" are both non-zero exits and only one of
them says anything about the contract.

The refusal-propagation property was control-tested by deleting `build-test`'s
acquisition guard from an in-memory mutant, which reddens it with
`Verjson/verjson-ci#184`'s exact failure mode — a required check concluding
success on a lane that declined to do the work.

Requirements 2 and 3 of #1369 (PR #1399), consolidated into this entry because
`NEXT/` holds one fragment per identity; requirement 5 remains follow-up work.

## The generated adopter set moves as one commit

Requirement 5 (PR for #1369). The set `scripts/gen-changelog-caller.sh` emits —
the changelog caller, the PR gate, the renderer, the emitted contract test, the
release caller, the release proposer, the split generated-artifacts caller and
the ADR index test — is one artifact spread across several files, all pinned to
one contract commit. "A partial regeneration is the divergence the generator
exists to prevent" was, until now, prose in the generated headers. Prose does
not redden. The only machine-checked expression of it was an org Renovate
grouping rule, which bumps *action digests* together and says nothing when a
human regenerates half the adopter set by hand.

The emitted contract test now compares every member's declared pin against the
commit it was itself generated at, before any per-member assertion runs, and
reports **all** divergent members in one verdict naming each member, the commit
it still claims, and the commit the set is pinned at. The per-member assertions
that already existed stop at whichever divergence they reach first, so fixing a
two-member subset regeneration used to take two round trips.

Each finding carries the regeneration command for its member. That command is
composed from a mode literal in the generator and the suite's own
`CONTRACT_REF`; nothing in it is derived from the file being reported on.

Every arm reports positive evidence. A member that is absent, unreadable, not a
regular file, unscannable, emptied to zero bytes, carrying a pin declaration
that no longer parses, or declaring two different pins is a finding in its own
right — the check can no longer establish that member was generated at the pin,
and reading that as conformance is the defect class the matrix exists to close.
With the check removed from the generator, six of those states pass silently and
the whole-set case reports nothing; the hub suite was run against exactly that
mutant, and fourteen of the new cases redden against it.

A member's header is adopter-controlled text on roughly ninety-five
repositories. It is read as a **claim**, constrained to forty lowercase hex
characters and compared as a string — never evaluated, sourced, or used to build
what the hub executes. A fixture plants `CONTRACT_REF="$(touch …)"`, and the
suite asserts both that it is refused and that the planted command left no
trace. That pair was control-tested against a deliberately permissive,
`eval`-ing variant of the checker, which does create the witness file.

Optional members remain optional: a repository that never adopted Renovate
attribution, a release proposer or the ADR index is not failed for the absent
file. Once present, it is held to the same pin as everything else. Requirements
1 and 4 of #1369 remain follow-up work.

Requirement 5 also surfaced a fail-open in `required-checks-audit.sh`, found
because the larger generated contract test tripped it. `base64 --decode` exits 0
on an empty stream, so an artifact the contents fetch did not return landed as a
zero-byte file that every check downstream read as content — the byte comparison
reported drift, and the parameter extraction reported invalid
scope/node/package-dirs, for an artifact that was never retrieved. It is now a
named `generated-contract-artifact-empty` fault. The empty stream came from the
audit's own test stub, which passed base64 through `jq --arg` on the command
line; a single argument is capped at `MAX_ARG_STRLEN` (128 KiB on Linux) against
a 4/3 base64 expansion, so it began failing with `E2BIG` once the generated
contract test passed roughly 96 KiB. It is 96 KiB now and grows with every
contract addition, so the stub passes the content through a file.
