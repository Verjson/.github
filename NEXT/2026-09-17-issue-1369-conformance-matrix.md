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
release caller, the release proposer, the Renovate attribution caller and the
ADR index test — is one artifact spread across several files, all pinned to one
contract commit. "A partial regeneration is the divergence the generator
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
that no longer parses, declaring two different pins, or declaring a generator
mode that does not write its path is a finding in its own right — the check can
no longer establish that member was generated at the pin, and reading that as
conformance is the defect class the matrix exists to close.

The hub suite was run against a mutant of the generator with the whole block
deleted, and these numbers are measured rather than reasoned. Nineteen cases
redden, and exactly **three** of them redden by *accepting* a state that is not
conformant: a changelog caller left at an earlier contract commit, a member
declaring two different pins, and this suite itself declaring two. Every other
divergent or malformed member does redden — but on a pre-existing per-member
assertion that names neither the commit the member claims nor the commit the set
is pinned at, so none of those messages was ever evidence about the pin, and
correcting a subset regeneration from them means rediscovering one member per
iteration. That is the reporting this block replaces, not a gap it opens. The
remaining cases are the block's own whole-set, every-member-at-once and
remedy-wording assertions, which have nothing to report once it is deleted.

A member's header also states which generator mode produced it, and that is part
of the claim rather than decoration: a `changelog.yml` carrying a `pr-gate`
header at the correct commit is not the changelog caller. Each member names the
modes that write its path, so a verdict printed before every per-member
assertion never agrees with a file it has not identified. Where several modes
write one path the remedy names all of them and says how they differ — a remedy
hardcoded to one mode is worse than none across ninety-five repositories, since
following `generated-artifacts` on a repository that adopted
`generated-artifacts-with-adr-index` silently drops `adr-index: true`, the
pinned `scripts/gen-adr-index.sh`, and the generator-test path with it. Every
enumerated member is itself checked against the paths the generator's usage
block says it writes, so a member no mode can produce cannot be enumerated.

A member's header is adopter-controlled text on roughly ninety-five
repositories. It is read as a **claim**, constrained to forty lowercase hex
characters and compared as a string — never evaluated, sourced, or used to build
what the hub executes. A fixture plants `CONTRACT_REF="$(touch …)"`, and the
suite asserts both that it is refused and that the planted command left no
trace. That pair was control-tested against a deliberately permissive,
`eval`-ing variant of the checker, which does create the witness file.

Optional members remain optional: a repository that never adopted Renovate
attribution, a release proposer or the ADR index is not failed for the absent
file. Once present, it is held to the same pin as everything else.

That is a limitation as much as a feature, and it is stated rather than left to
be inferred: **this check cannot tell a deleted optional member from one that
was never adopted, so the deletion passes.** An earlier draft of this paragraph
gave a reason that is false, and it is corrected here rather than quietly
dropped: it claimed the emitted suite holds *no* hub-controlled record of what
the adopter selected, because "`--autonomy` and the release flags are consumed
by `release-propose` and `release-node` and never reach `contract-test`". Only
the `--autonomy` half is true (`gen-changelog-caller.sh:239`).
`gen-changelog-caller.sh:179` explicitly accepts `--release-asset` for
`contract-test`, and the emitted suite bakes in fourteen hub-controlled values
— eleven `EXPECTED_RELEASE_*` parameters and three digests. Measured on this
branch: generated plainly, `EXPECTED_RELEASE_ASSETS_JSON` is `'[]'`; generated
with `--release-asset dist/x.tgz` it is `'["dist/x.tgz"]'`, and that line is the
*only* difference between the two emitted suites. A non-default value there is
therefore already a hub-controlled record that a release caller was selected,
and for that subset a deleted `release.yml` **is** distinguishable from "never
adopted".

What is actually missing is narrower than "record the selected modes at
generation time", and the gap is a use, not a record. A sentence of this
paragraph is now withdrawn for the same reason its predecessor was: it claimed
that *every release assertion in the emitted suite sits behind*
`if [ -f "$release_workflow" ]`. Re-measured by generating the suite at this
branch's head and reading it, that literal occurs exactly **once**, guarding a
single `workflow_dispatch` assertion; the other 98 release assertions sit inside
a *discovery loop* over every workflow whose text contains
`changelog-release.yml@`, which collects nothing at all when no such workflow
exists. (That one guarded assertion reads the loop variable after the loop has
ended, so it checks only the last discovered caller — pre-existing, failing
toward a miss, tracked as #1488.) The conclusion survives and the mechanism is
worse than the withdrawn one described: an absent release caller is not skipped
by a guard, it is never discovered, so the recorded selection is still never
read as a *presence* requirement. Closing it in general is
still a contract-shape change, because the record only covers what a flag
varies. The ADR members carry no such signal at all: `ADR_INDEX_SHA256` and
`ADR_INDEX_TEST_SHA256` came out byte-identical across every flag combination
`contract-test` accepts, being the digest at the pinned ref whether or not the
adopter ever wired `adr-index: true`. Requirements 1 and 4 of #1369 remain
follow-up work.

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

Review of the same commit found the identical fail-open one function away, at
the audit's workflow-source fetch. There it did not merely mis-name a fault: an
empty `$source` makes the workflow inspector report absent changelog wiring and
no path filter, and the caller scan find no job, so the repository was reported
**nonconformant** with `stack-caller-missing` for a workflow that was never
retrieved. The fetch is the only place that can distinguish "returned nothing"
from "wires nothing", so it fails closed there and the repository is counted
unaudited. The inspector's behavior on empty input is asserted directly, because
it is the reason the guard cannot live any further downstream.
