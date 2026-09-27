# 0193 — Every `scripts/ci-gate/` script is a gate unless it is declared a library

- **Date:** 2026-09-18
- **Status:** Accepted
- **Related:** [ADR 0076](../0076-bounded-actions-ci-shell-test-groups/README.md), [ADR 0184](../0184-merge-gates-assert-execution-not-absence-of-red/README.md)
- **Issues:** [#1320](https://github.com/Verjson/.github/issues/1320), [#1450](https://github.com/Verjson/.github/issues/1450), [#1477](https://github.com/Verjson/.github/issues/1477)

## Context

[#1320](https://github.com/Verjson/.github/issues/1320) found nine gate tests that had
been deregistered from `scripts/actions-ci-groups.tsv` and left in the tree. They kept
passing locally and ran nowhere in Actions for a month. The fix was an orphan detector in
`scripts/actions-ci-groups.test.sh`: every candidate script must be reachable from an
execution path Actions actually takes, or the check reddens.

The detector found its candidates by the `*.test.sh` / `*.test.py` suffix. That worked
only because, at the time, every registered gate happened to be a test.
`scripts/ci-gate/hub-changelog-validate.sh` ([#1425](https://github.com/Verjson/.github/issues/1425),
PR #1446) is a gate and not a test, so the detector could not see it: removing its row
from the manifest left the whole suite green with the gate running nowhere — the exact
#1320 failure, one filename suffix away. #1446 pinned that one registration from inside
`hub-changelog-validate.test.sh`. That closes one hole and creates a worse invariant: the
next non-test gate is unprotected again, and nothing signals it.

Widening the detector required deciding something the suffix rule had been standing in
for: **what distinguishes a registered gate script from an ordinary helper under
`scripts/ci-gate/`?** The directory holds both: 118 gate tests, 15 non-test scripts a
workflow invokes directly, one non-test gate reachable only through the manifest, and a
four-module conformance package that is imported and never invoked.

Three candidate discriminators were evaluated against the tree:

- **Executable bit / shebang.** Rejected on the evidence: every tracked file under
  `scripts/ci-gate/` is mode `100644`, the conformance library modules all carry
  shebangs, and two genuine `*.test.py` files do not. The signal does not exist here.
- **Imported by another ci-gate script.** Self-maintaining, but silent: a real gate that
  anything imports becomes exempt without anyone deciding that, which is the same class
  of accident as the suffix.
- **Closed-world accounting with a declared exception list.** Chosen.

## Decision

Every tracked `*.sh` or `*.py` file under `scripts/ci-gate/` is a gate script and must be
reachable in Actions, unless it is declared a library module in
`scripts/actions-ci-groups.test.sh` with a stated reason, is imported by another tracked
`scripts/ci-gate/` script, and is not invoked as a command on a tracked execution path.

"Reachable in Actions" means the path is named:

1. as a command argument in `scripts/actions-ci-groups.tsv`; or
2. in the `hosted-compatibility-tests` run step of `.github/workflows/actions-ci.yml`; or
3. anywhere in a tracked workflow or composite action under `.github/`.

Route 3 is what keeps the declared list honest and short: the fifteen scripts a workflow
invokes directly do run in Actions, so calling them "helpers" would have been a lie. Only
four files — the `scripts/ci-gate/conformance/` modules — are declared, each with the
reason it can never be a manifest row.

Consequences of the classification:

- Adding a file under `scripts/ci-gate/` has exactly two honest outcomes: register it
  where Actions runs it, or declare it a library with a reason. Neither happens by
  accident, and nothing is exempt by virtue of what it is called.
- A declaration that goes stale — the path stops being tracked, is no longer imported, or
  is invoked as a command after all — reddens the same check. These checks bind the
  declaration to the common, observable library shape rather than trusting its prose.
  Whether an imported file also has meaningful standalone gate behavior is still not a
  computable property here; review of a diff to this list remains the final control, which
  is why the list lives in the gate file rather than in a data file nobody reads.
- The candidate set is enumerated with `git ls-files`, not a filesystem walk: the index is
  what Actions checks out, so an untracked scratch file is correctly not a gate and a
  tracked one cannot hide from a glob.
- The per-file pin #1446 added inside `hub-changelog-validate.test.sh` is removed. Its one
  additional assertion — that the registration sits in the `platform` group — moved to the
  load-bearing command list in `scripts/actions-ci-groups.test.sh`, which owns group
  assignment. Per-file pins are not the pattern; if one is ever needed again, that is
  evidence this rule is wrong rather than evidence the pin was right.

## 2026-09-23 refinement — bind declarations to observable module behavior

[#1477](https://github.com/Verjson/.github/issues/1477) demonstrated that the declaration
list still acted as a review-only suppression vector: a real, executable, unregistered
gate could be added to `NON_GATE_MODULES` and the check passed. The earlier staleness
assertions proved only that the path existed and was not registered; they did not test the
reason the declaration gave for exemption.

Each declaration now has two additional invariants: at least one other tracked
`scripts/ci-gate/` Python script must statically import the exact module, and no tracked
Actions execution block may invoke the declared path as a command. Imports are resolved
to tracked paths relative to the ci-gate root and the importing package; a coincidental
basename or suffix does not satisfy the declaration, and an import that resolves to more
than one tracked path fails as ambiguous. Relative imports resolve aliases from the
importing package; an empty module never aliases a sibling file, and packages resolve only
through tracked `__init__.py` files. For `from module import Name`, a resolved `module.py`
makes `Name` an attribute; alias submodules are considered only when the base is a regular
or namespace package. Command discovery folds Bash line continuations before tokenization
and treats relative, workspace-variable, trusted-checkout,
punctuation, and unsupported wrapper spellings that mention the path as invocations.
Tokenization errors that mention a tracked gate path fail closed.

End-to-end mutation controls replace the real import with an unrelated same-basename
import, introduce ambiguous, relative-package, and module-attribute filename collisions,
and add each command spelling through a synthetic workflow document, including a line
continuation and malformed shell source.
Every mutation reruns parsing, discovery, normalization, and the declaration decision,
and must fail while naming the declared module. This closes the tractable suppression case
without claiming to decide whether arbitrary imported code is semantically a library. The
general execution-path limitation below remains explicitly out of scope.

## Residual, accepted deliberately

This proves a gate is **named on** an Actions execution path, not that the path
**executes**. A script named only by a workflow whose triggers never fire, or reached
only through an `if:` that is never true, still counts as reachable here. So does one
named only by a `sparse-checkout:` entry or an `env:` value while its actual invocation
is deleted: the match is against the whole workflow text, and both shapes exist in this
tree today. Workflow reachability is a different invariant with a different shape — it
belongs to ADR 0184's line of work (a gate asserting that verification executed), not to
a static inventory check — and conflating them would make this check both weaker and
harder to reason about.

Files under `scripts/ci-gate/` that are neither `*.sh` nor `*.py` (JSON and YAML fixtures,
allowlists) are out of scope: they are data read by a gate, not something Actions could
run. Scripts outside `scripts/ci-gate/` are likewise unchanged; the root `scripts/`
directory mixes generators, installers, and gates, and drawing this line there is separate
work that would need its own evidence.

## Alternatives rejected

- **Keep the suffix rule and pin each non-test gate in its own test.** This is the status
  quo #1450 was filed against. It scales by remembering, and the failure is silent.
- **Broaden the suffix to a second naming convention** (`*-gate.sh`, `*-validate.sh`).
  Encodes the rule in a regex where nobody reads it and renames a file into or out of CI
  coverage.
- **Require every ci-gate script to be in the manifest, with no workflow route.** Would
  force fifteen workflow-invoked scripts into a second, redundant execution path or into
  a much longer exception list, and would mislabel real gates as helpers.
