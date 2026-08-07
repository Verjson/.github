# Gate coverage audit

Run the fleet audit before adding the `gate` context to an organization-wide
required-check rule:

```bash
python3 scripts/gate_coverage_audit.py
```

The default is always dry-run. It emits one JSON object per open PR whose head
lacks the current `gate` check, followed by a summary. Each record names the
exact `owner/repo#PR`, exclusion state (`draft`, `hold`, `fork`), canonical
workflow availability, legacy/current context evidence, and the proposed
supported retrigger.

Repository-local active workflows use the canonical `re-review` label.
Organization-required workflows use reversible close/reopen because required
workflows do not receive `labeled` events (#477). Both create PR-associated
events, unlike `workflow_dispatch`, and neither pushes or merges another
repository's branch.

Mutation requires two independent choices:

```bash
python3 scripts/gate_coverage_audit.py \
  --apply \
  --authorize-repo Verjson/example \
  --authorize-repo Verjson/second-example
```

Only exact authorized repositories can change. Eligible findings elsewhere are
reported as `refused_unmanaged`; drafts, holds, forks, missing/disabled
workflows, truncated check data, rate limits, and unavailable metadata never
become mutations.

Close/reopen is a two-call operation. If reopening fails, the command fails
closed and prints the exact target so the owning PM can restore it; this is why
required-workflow retriggers demand explicit repository authority.

Group refused records by repository and route one compact handoff to that
repository's owning PM. Do not open one issue per pull request. Re-run dry-run
after authorized sweeps; ADR 0058's `~ALL` gate requirement remains blocked
until `missing_gate` reaches zero.
