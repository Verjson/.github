# 0025 — Release-tooling audit accepts dated, per-advisory exceptions

- **Date:** 2026-07-25
- **Issue:** [Verjson/.github#146](https://github.com/Verjson/.github/issues/146)
- **Category:** supply-chain / CI security gate (sensitive class — this reshapes a
  security gate and knowingly accepts one high advisory on a timer)

## Context

`actions-ci.yml` gated the release tooling with a bare invocation:

```
npm audit --package-lock-only --omit=dev --audit-level=high
```

On 2026-07-25 that step turned **every PR in the repo red**, with no code change.
`main` was green at `b2e57be` (2026-07-24T16:47Z); the newly-published advisory
[GHSA-mh99-v99m-4gvg](https://github.com/advisories/GHSA-mh99-v99m-4gvg)
(`brace-expansion <=5.0.7`, **high**, DoS via unbounded expansion causing an OOM
crash) landed after it. Two in-flight PRs (#144, #145) were collateral.

The advisory is **not fixable from our side**. The vulnerable copy is
`node_modules/npm/node_modules/brace-expansion` — a **bundled** dependency inside
the `npm` package, reached via `semantic-release@25.0.8` →
`@semantic-release/npm@13.1.5` → `npm@11.18.0`. Verified against the live registry:

| attempt | result |
| --- | --- |
| `npm audit fix --package-lock-only` | no-op, lock unchanged |
| bump `semantic-release` | already on `25.0.8`, the latest published |
| `overrides: { "brace-expansion": "^5.0.8" }` | lock still resolves `5.0.7` |
| `overrides: { "npm": "12.0.1" }` | `npm@12.0.1` **still bundles** `5.0.7` |

`overrides` do not rewrite bundled dependencies, and npm has published no release
carrying `brace-expansion@5.0.8`.

The deeper problem is the gate's shape, not this advisory. `--audit-level` is
all-or-nothing: a single unfixable transitive advisory in **release** tooling can
wedge CI for the whole org, and the only escapes are to weaken the gate wholesale
(`--audit-level=critical`) or delete the check. The gate cannot express the thing
a human actually decided: *"this specific advisory is known, assessed, and accepted
until upstream ships."*

## Decision

Replace the bare invocation with **`scripts/release-tooling-audit.sh`**, a
fail-closed wrapper over `npm audit --json --package-lock-only --omit=dev`, and
keep the exceptions in a separate, obvious data file,
**`.github/release-tooling/audit-allowlist.json`**, so a reviewer diffing a PR
sees exactly what is being excused and until when. Allowlist entries are **never**
buried in shell.

The verdict is taken **per package, not per advisory** — the same unit
`--audit-level` graded. Every package npm reports at high/critical is resolved
through its `via` chain (objects are advisory roots, strings are propagation edges
to another reported package) to a set of advisories; the package passes only if
**every** one of them is excused. This is the load-bearing detail: deriving the
verdict from `via[]` objects alone lets a package npm graded critical pass whenever
its advisory cannot be read back out of the report (see the 2026-07-25 rework note
in Consequences).

The wrapper blocks when **any** of these holds:

1. a package graded **high or critical** resolves to an advisory the allowlist does
   not excuse — matching on GHSA id **and** package **and** severity, so an entry
   excuses one advisory in one package and nothing else;
2. such a package is **unattributable** — its `via` chain is empty, dangles at a
   package the report does not carry, or yields an id that is not a GHSA. An
   unexplained critical is a block, never a pass;
3. an allowlist entry is **stale** — today is past its `review-by` — so an accepted
   risk cannot silently become permanent;
4. an allowlist entry **matches no reported advisory** — so a resolved advisory's
   exception is deleted rather than lingering as dead permission;
5. the report cannot be fully interpreted: absent/malformed JSON, valid JSON of the
   wrong shape, an npm exit it cannot interpret, a jq evaluation error, a severity
   outside `{info,low,moderate,high,critical}` (case-insensitive), non-numeric
   severity counts, or npm counting more high/critical packages than could be
   enumerated. **An unreadable audit must never read as "clean."** npm's own exit
   code decides nothing (it is non-zero whenever it reports anything at all); the
   JSON does.
6. the allowlist itself is missing, empty, or malformed — every entry must carry a
   GHSA id, the package and severity it excuses, a non-empty reason, and a
   `review-by` that is a **real calendar date** no more than 90 days out. An
   undated, unreasoned, ISO-shaped-but-impossible (`2026-13-45`) or far-future
   (`9999-12-31`) exception is a permanent exception by omission, and is rejected.

Moderate and below stay non-blocking, preserving the `--audit-level=high`
threshold the wrapper replaces.

The allowlist is seeded with **exactly one** entry:

- **GHSA-mh99-v99m-4gvg** · `brace-expansion` · high · **review-by 2026-08-25**
  (30 days) — DoS in the copy bundled inside npm's own CLI, exercised only at
  publish time on our own runners against our own inputs; not attacker-reachable in
  CI. No upstream fix installable as of 2026-07-25.

`scripts/release-tooling-audit.test.sh` drives the real script against **stubbed**
`npm audit --json` output (never the network) across 29 cases — clean report,
unlisted high, unlisted critical, allowlisted high, moderate below threshold, stale
entry, unmatched entry, malformed JSON, wrong-shape JSON, empty output with a
non-zero npm exit, npm absent from `PATH`, absent / zero-byte allowlist, undated /
non-ISO / impossible-date / far-future / reasonless entries, an entry naming the
wrong package and severity, the `review-by` boundary day, a second unlisted high
beside an excused one, an unattributable critical **alongside a live allowlist
entry**, an advisory with an absent or uppercase severity, non-numeric severity
counts, and the wiring itself — and is wired into `actions-ci.yml` (an unwired test
does not run; that gap once left `hold.test.sh` dormant). The cases that pair a
live allowlist entry with a broken report are deliberate: with an empty allowlist
the shape guards mask each other, which is exactly how the original fail-open
survived review.

## Consequences

- **This knowingly accepts a known high advisory, on a timer.** Between now and
  2026-08-25 the release tooling installs a `brace-expansion` with a published DoS.
  The assessment is that it is not attacker-reachable from CI — it runs inside
  `semantic-release`'s own publish path, on our self-hosted runners, over our own
  repository's inputs — but this is an accepted risk, not a fixed bug. On
  2026-08-26 CI fails again by design and a human must re-assess or drop the entry.
- The gate is **stricter** in every direction except the one explicitly excused:
  it fails closed on report shapes the old `--audit-level` flag would have
  swallowed, and it fails on dead, undated or over-long exceptions, which no
  `--audit-level` setting can express. **This claim was false in the first draft
  of this decision, and the correction is the point of the note below.**
- **Rework, 2026-07-25 (pre-merge, review of #147).** The first implementation
  derived the verdict from `via[]` advisory objects and guarded the extraction with
  "npm counted high/critical packages but *no* advisory was extracted". That guard
  counted **all** extracted advisories, excused ones included, so the day the
  allowlist gained its first entry the count was permanently ≥ 1 and the guard could
  never fire again. A report carrying the excused `GHSA-mh99-v99m-4gvg` plus a
  critical package whose `via` dangled at an unreported name exited **0** — the gate
  was weaker than the `--audit-level=high` it replaced, in the one configuration it
  ships in. The same path also passed a critical whose advisory omitted `severity`
  or spelled it `"CRITICAL"`. Fixed by taking the verdict per package (above),
  turning the drift guard into a coverage check (`counted > enumerated` blocks
  regardless of the allowlist), and rejecting unknown severities instead of
  defaulting them to `"unknown"`. Evidence: the test named
  *"unattributable critical alongside an excused advisory fails closed"* passes on
  the current script and fails on the pre-fix one.
- A `review-by` is now validated as a **date**, not a shape: it is round-tripped
  through `date -u -d` and must come back unchanged, and it must fall within 90 days.
  `2026-13-45` and `9999-12-31` both previously passed every check, and either would
  have been a permanent bypass hiding in plain sight as a typo.
- `package` and `severity` were documented allowlist fields but were never read, so
  an entry naming any package at any severity excused its GHSA everywhere. They are
  now required and matched against the advisory as npm reports it, which narrows an
  exception to exactly the risk that was assessed.
- The escape hatch is bounded and auditable: an exception is one reviewable JSON
  entry with an author-supplied reason and a hard expiry, visible in the PR diff.
  It is not a global severity downgrade.
- Renovate will still raise a `semantic-release` bump whenever upstream ships a fix;
  at that point the allowlist entry stops matching and the gate **fails until the
  entry is removed**, which is the intended forcing function.
- New dependency on `jq` in this step. It is already required by
  `node-workflow-pins.test.sh` and the ADR-index generator on the same pool.

## Sensitive-hunk diff

The security gate itself, `.github/workflows/actions-ci.yml`:

```diff
-      - name: reusable Node workflows — release lock has no high-risk advisories (#89)
-        working-directory: .github/release-tooling
-        run: npm audit --package-lock-only --omit=dev --audit-level=high
+      - name: release-tooling audit — allowlist expiry and fail-closed parsing (#146)
+        run: bash scripts/release-tooling-audit.test.sh
+      - name: reusable Node workflows — release lock has no high-risk advisories (#89, #146)
+        run: bash scripts/release-tooling-audit.sh
```

The accepted risk, `.github/release-tooling/audit-allowlist.json` (new):

```diff
+  "allowlist": [
+    {
+      "ghsa": "GHSA-mh99-v99m-4gvg",
+      "package": "brace-expansion",
+      "severity": "high",
+      "reason": "DoS via unbounded expansion in the copy of brace-expansion bundled inside npm's own CLI ... not attacker-reachable in CI. No upstream fix is installable as of 2026-07-25 ...",
+      "review-by": "2026-08-25"
+    }
+  ]
```

Verified against the real lockfile: the wrapper exits **0** with the entry present,
and exits **1** both with the entry removed (`unexcused high/critical package(s):
high brace-expansion GHSA-mh99-v99m-4gvg`) and with the clock moved past `review-by`
(`allowlist entr(ies) are past their review-by (2026-08-26)`).

See [#146](https://github.com/Verjson/.github/issues/146) for the full diagnosis.
