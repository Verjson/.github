---
date: 2026-08-02
issue: 279
title: Bind privileged-merge gate provenance to the run's entry workflow
---

`ai-privileged-merge.yml` trusted a gate run whose `referenced_workflows[]` named
`ai-review-merge.yml` at `main`'s SHA. That array describes the workflow **file**,
not what executed — a job under `if: false` still lists its callee — so one
crafted workflow in a consumer repository could mint every signal the merge asks
for (reference the gate it never runs, publish a job literally named `gate` that
succeeds, upload a hand-written `merge-attestation-<run_id>` artifact) and obtain
an `--admin` merge. Pre-existing; found by the adversarial review in #277.

`trusted_run` now additionally requires the run's `path` — the entry workflow
GitHub actually started — to be `.github/workflows/ai-review-merge.yml`, as a
conjunct on **all three** installation matchers. Verjson repositories are
unaffected: they install the gate as the org required workflow (ADR 0039), whose
entry path is already the gate path. A cross-org consumer on the ADR 0022
reusable shape must keep its thin caller at that same path.

The fork-PR exposure stays closed by `workflow_files_changed`, which is
**load-bearing rather than defence in depth** and is now commented as such at the
function. Residual: a write-access actor placing a crafted file at exactly the
canonical path is observationally identical to an honest caller and needs signed
provenance (#261) to separate. `ai-review-merge.yml` has no equivalent guard on
its own direct merge path — filed separately.

New `scripts/ci-gate/entry-workflow-provenance.test.sh` (wired into `actions-ci`)
pins the binding on both merge paths and the fail-closed handling of
absent/null/empty API fields. Refs ADR 0044, and ADR 0036 / 0039 / 0042.

An adversarial review of the first draft found the entry conjunct alone still
merged a forged run in the required-workflow shape — the shape every Verjson
repository uses. A write-access actor who *adds* a repo-local
`.github/workflows/ai-review-merge.yml` naming the gate satisfies both the entry
path and the reference matcher. The matchers are therefore exclusive rather than
additive: where the organization ruleset mandates the gate, only the run it
injected (`workflow_url` under `/actions/required_workflows/`) is trusted. The
documented cross-org caller example moves to the canonical filename for the same
reason — under the entry binding, a caller at any other path reviews correctly
and is then refused its merge.
