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

The wrapper blocks when **any** of these holds:

1. a **high or critical** advisory is not named in the allowlist;
2. an allowlist entry is **stale** — today is past its `review-by` — so an accepted
   risk cannot silently become permanent;
3. an allowlist entry **matches no reported advisory** — so a resolved advisory's
   exception is deleted rather than lingering as dead permission;
4. the report cannot be fully interpreted: absent/malformed JSON, valid JSON of the
   wrong shape, an npm exit it cannot interpret, a jq evaluation error, or npm
   counting high/critical packages that no advisory object can be attributed to.
   **An unreadable audit must never read as "clean."** npm's own exit code decides
   nothing (it is non-zero whenever it reports anything at all); the JSON does.
5. the allowlist itself is missing or malformed — every entry must carry a GHSA id,
   a non-empty reason, and a `YYYY-MM-DD` `review-by`. An undated or reasonless
   exception is a permanent exception by omission, and is rejected.

Moderate and below stay non-blocking, preserving the `--audit-level=high`
threshold the wrapper replaces.

The allowlist is seeded with **exactly one** entry:

- **GHSA-mh99-v99m-4gvg** · `brace-expansion` · high · **review-by 2026-08-25**
  (30 days) — DoS in the copy bundled inside npm's own CLI, exercised only at
  publish time on our own runners against our own inputs; not attacker-reachable in
  CI. No upstream fix installable as of 2026-07-25.

`scripts/release-tooling-audit.test.sh` drives the real script against **stubbed**
`npm audit --json` output (never the network) across 20 cases — clean report,
unlisted high, unlisted critical, allowlisted high, moderate below threshold, stale
entry, unmatched entry, malformed JSON, wrong-shape JSON, empty output with a
non-zero npm exit, absent allowlist, undated / non-ISO / reasonless entries, the
`review-by` boundary day, a second unlisted high beside an excused one, and the
wiring itself — and is wired into `actions-ci.yml` (an unwired test does not run;
that gap once left `hold.test.sh` dormant).

## Consequences

- **This knowingly accepts a known high advisory, on a timer.** Between now and
  2026-08-25 the release tooling installs a `brace-expansion` with a published DoS.
  The assessment is that it is not attacker-reachable from CI — it runs inside
  `semantic-release`'s own publish path, on our self-hosted runners, over our own
  repository's inputs — but this is an accepted risk, not a fixed bug. On
  2026-08-26 CI fails again by design and a human must re-assess or drop the entry.
- The gate is now **stricter** in every direction except the one explicitly
  excused: it fails closed on report shapes the old `--audit-level` flag would have
  swallowed, and it fails on dead or undated exceptions, which no `--audit-level`
  setting can express.
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
and exits **1** both with the entry removed (`unexcused high/critical advisor(ies):
high GHSA-mh99-v99m-4gvg`) and with the clock moved past `review-by`
(`allowlist entr(ies) are past their review-by (2026-08-26)`).

See [#146](https://github.com/Verjson/.github/issues/146) for the full diagnosis.
