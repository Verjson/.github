# 0006 — AI-work rework telemetry: observe-and-report, human holds the dial

- **Date:** 2026-07-18
- **Issue:** Verjson/.github#33 · schema Verjson/verjson-observability#49
- **PR:** Verjson/.github#34
- **Category:** AI governance / verification calibration (observe-and-report) —
  sensitive-class (it measures how much the org trusts AI-authored work)
- **Amended by:** ADR 0007 (adds human-set adaptive gating on top of observe-and-report)
- **Amended:** 2026-07-29 — credential scope for cross-repository reads (see below)

## Context

We want "trust but verify" for AI-authored work to be **data-driven, not vibe**:
verification effort should scale with blast radius and with each category's track
record — verify docs / CI-caller swaps lightly, auth / migrations heavily. That
requires measuring **rework** (reverts, fix-follows-merge, post-merge main
breakage) per change-category and per AI-authorship, over time.

But a system that measures how much to trust the AI is itself a governance hazard:
if the AI owns or can act on that measurement, it can grade its own homework and
loosen its own guardrails (conflict of interest), and any metric that feeds back
into behaviour invites gaming (Goodhart — PR-splitting, risk-avoidance).

The org already has the telemetry substrate (ADR 0004: `verjson-observability`
`CiTelemetryPayload` → `emit-ci-telemetry` → OTLP → Grafana), but it emits **at
event time**; rework is **retrospective** and needs a scheduled reconciler.

## Decision

1. **Build the rework telemetry as observe-and-report only.** It measures and
   surfaces; it **never mutates merge or verification gates**. At most it
   *proposes* — opens an issue when a category crosses a threshold. **A human
   holds the dial.**
2. **The AI does not own the trust-measurement mechanism.** The reconciler code
   and its thresholds are human-reviewed; humans decide how the numbers change
   verification policy.
3. **Architecture:** emit-time enrichment (`ai_authored` from the
   `Co-Authored-By: Claude…` trailer, `change_category`, pre-merge friction) +
   a **scheduled reconciler** in `Verjson/.github` (alongside `scripts/ci-telemetry/`)
   that attributes rework by **precision tier** — reverts / explicit fix-refs
   (high), `fix:` in same area within window (medium), post-merge CI fail
   (objective), raw file-overlap (low, flag-for-review only, **excluded from the
   headline rate**).
4. **Schema lives upstream** in `verjson-observability` (`ReworkTelemetryPayload`,
   bounded numeric/enum only), per the internal-packages convention — not inlined
   in the consumer.
5. **MVP is a weekly summary issue / report artifact** from a pure GitHub-API job,
   so the calibration signal lands before the (currently dormant) OTLP collector
   is routable from the runners.

## Consequences

- Verification effort can shift per category **with evidence**, and the shift is a
  human decision backed by data.
- Conflict-of-interest and Goodhart are guarded **by construction**: report-only,
  human-owned thresholds, human-reviewed reconciler.
- Metrics are directional, not precise: per-category counts are small — wide
  windows, always surface `sample_size`, never over-interpret.
- The dashboard depends on the ADR-0004 OTLP pipeline being activated; the MVP
  report path avoids blocking on that infra.

## Follow-up

- Implement the reconciler + enrichment per Verjson/.github#33.
- Add `ReworkTelemetryPayload` per Verjson/verjson-observability#49.
- Activate the OTLP exporter (ADR 0004 follow-up) to light up the Grafana panel.

## Amendment — 2026-07-29: credential scope for cross-repository reads

- **Issue:** Verjson/.github#157 · **PR:** Verjson/.github#183

The reconciler reads seven sibling repositories, which `GITHUB_TOKEN` cannot reach, so a
separate `REWORK_RECONCILE_TOKEN` secret is required. This amendment fixes its scope; it
does not reopen the observe-and-report decision above.

That credential is limited to **Metadata, Pull requests, and Contents — all read-only**,
across exactly the repositories in `.repos[]` of `.telemetry/rework-thresholds.json`.
Write access to pull requests, contents, or checks/statuses would put the reconciler in a
position to influence the merge and verification gate it exists to observe, which is the
boundary this ADR forbids. The workflow's own `permissions:` block is not a backstop: a
PAT carries its own grants, so least privilege has to be set at mint time.

Provisioning and rotation runbook: `docs/rework-telemetry.md`.
