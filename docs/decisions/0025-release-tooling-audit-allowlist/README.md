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
   excuses one advisory as npm reports it and no other;
1b. such a package is graded **above every** severity its excusing entries accepted
   — i.e. **no** excused advisory under it reaches the package's own grade. npm
   grades the package (the unit `--audit-level` gated on) at the **max** over its
   chain, so an entry accepting a `high` advisory does not carry a package npm calls
   `critical`: the severity a reviewer wrote down is the severity they assessed. The
   test is deliberately "**some** excused advisory reaches the grade", not "every one
   does": because npm grades by max, a chain that also reaches a lower-graded advisory
   is the ordinary multi-CVE/multi-hop shape, and since an entry's severity is copied
   from npm's report rather than chosen, the stricter reading would make such a
   package unexcusable by **any** allowlist — reinstating the unbypassable wedge this
   ADR exists to remove;
2. such a package is **unattributable** — its `via` chain is empty, dangles at a
   package the report does not carry, or yields an id that is not a GHSA. An
   unexplained critical is a block, never a pass;
3. an allowlist entry is **stale** — today is past its `review-by` — so an accepted
   risk cannot silently become permanent;
4. an allowlist entry **matches no reported advisory** — so a resolved advisory's
   exception is deleted rather than lingering as dead permission;
5. the report cannot be fully interpreted: absent/malformed JSON, valid JSON of the
   wrong shape, an npm exit it cannot interpret, a jq evaluation error, a severity
   outside `{info,low,moderate,high,critical}` (case-insensitive), a severity count
   that is not a whole number ≥ 0, or npm counting more high/critical packages than
   could be enumerated. **An unreadable audit must never read as "clean."** npm's own exit
   code decides nothing (it is non-zero whenever it reports anything at all); the
   JSON does.
6. the allowlist itself is missing, empty, or malformed — every entry must carry a
   GHSA id, the package and severity it excuses, a non-empty reason, and a
   `review-by` that is a **real calendar date** no more than 90 days out. An
   undated, unreasoned, ISO-shaped-but-impossible (`2026-13-45`) or far-future
   (`9999-12-31`) exception is a permanent exception by omission, and is rejected.

What an entry does **not** do is excuse a package: it excuses an advisory. Because
npm propagates one advisory outward along `via`, a single entry can clear several
graded packages — every package whose chain resolves *only* to advisories that are
excused, and whose own grade the entry's severity covers (1b). That is deliberate
(the advisory is the thing assessed, and the chain to it is npm's bookkeeping), but
it is wider than "one package", so the allowlist `_readme` says so in those terms.

Moderate and below stay non-blocking, preserving the `--audit-level=high`
threshold the wrapper replaces.

The allowlist is seeded with **exactly one** entry:

- **GHSA-mh99-v99m-4gvg** · `brace-expansion` · high · **review-by 2026-08-25**
  (30 days) — DoS in the copy bundled inside npm's own CLI, exercised only at
  publish time on our own runners against our own inputs; not attacker-reachable in
  CI. No upstream fix installable as of 2026-07-25.

`scripts/release-tooling-audit.test.sh` drives the real script against **stubbed**
`npm audit --json` output (never the network) across 42 cases — clean report,
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

Coverage is measured by **mutation**, not by case count: each guard is inverted or
removed in a scratch copy of the script and the suite must go red. The six
mutations named in the 2026-07-25 review — dropping the dangling-edge poison, the
cycle guard, the empty-`via` poison, inverting the coverage comparison, degrading
the `review-by` round-trip to a non-empty check, and degrading the entry match to
GHSA-only — all survived a green suite before this round and are each red now.

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
- **Rework, round 3 — 2026-07-25 (pre-merge, second review of #147).** The
  per-package resolution above was correct but almost entirely **unpinned**: every
  `via` in the suite was one advisory object or one dangling string, so the
  recursion was never entered twice and six separate mutations of the script kept
  the suite green. Two of those were live defects, not just gaps:
  - The coverage guard compared counts with `[ "$counted" -gt "$found" ]`. `set -e`
    is off, so a count `[` refuses as an integer — `2.5`, or a whole number jq
    renders as `1e+100` — made the test *error* rather than compare, which skips
    the `&& die` beside it and the gate exited **0**. The comparison now happens in
    jq and the result is string-compared against a literal `true`; every remaining
    `[` in the script tests a string or a file, neither of which can error. This is
    the third time this batch that an erroring `[` has silently skipped its `die`.
  - An entry's `severity` bounded the **advisory**, never the package grade, so an
    entry accepting a `high` advisory cleared a package npm graded `critical` — the
    grade `--audit-level=high` actually gated on. Decision 1b above closes it: the
    entry's severity must cover the package's grade as well. The alternative — keep
    the advisory-only scoping and correct the docs — was rejected because it makes
    the accepted risk larger than the one written down, and the wrapper's whole
    claim is that it is stricter everywhere except the line a human signed.

    The related widening is **kept**, and the docs corrected instead: one entry can
    clear more than one graded package, when every one of those packages resolves
    only to advisories that entry excuses. `_readme` no longer says "and nothing
    else".
- **Rework, round 4 — 2026-07-25 (pre-merge, third review of #147).** The round-3
  grade check overshot: it blocked a package if **any** advisory in its chain graded
  below the package (`rank < package rank`), rather than if **none** reached it. But
  npm grades a package at the **max** over its chain, so reaching a lower-graded
  advisory alongside the top one is the ordinary multi-CVE/multi-hop shape — and
  because an entry's `severity` is matched against the advisory as npm reports it, an
  entry can never be written at a grade that clears such a package. That shape was
  therefore **unexcusable by construction**: brute-forcing all 25 severity pairs
  against a `critical` package whose `via` is `[critical advisory, moderate advisory]`
  cleared it in **0** of 25 — the unbypassable wedge this ADR exists to remove,
  reintroduced. The real lockfile escaped only by luck of the current advisory set
  (`brace-expansion` is the sole high, and its `via` is a single high advisory
  object). Decision 1b now reads "**some** excused advisory reaches the package's
  grade". Evidence: two new tests — a sibling mixed-grade chain and a multi-hop one,
  both fully excused — exit 0 on the current script and exit 1 on the round-3 rule;
  all three round-3 cases still hold (entry `high` vs package `critical` blocks, entry
  `low` vs package `high` blocks, entry `critical` vs package `high` passes).
- A `review-by` is now validated as a **date**, not a shape: it is round-tripped
  through `date -u -d` and must come back unchanged, and it must fall within 90 days.
  `2026-13-45` and `9999-12-31` both previously passed every check, and either would
  have been a permanent bypass hiding in plain sight as a typo. The two halves catch
  different implementations: GNU coreutils 9 *rejects* an impossible day outright
  (`2026-09-31` → exit 1), while busybox and older coreutils *accept and roll it
  over* (→ October 1), and only comparing the normalised value against the original
  catches that. Since the runner image is not part of this gate's contract, the test
  suite stubs a lenient `date` on `PATH` to exercise the round-trip — otherwise it
  reads as dead code on the box it happens to run on.
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
