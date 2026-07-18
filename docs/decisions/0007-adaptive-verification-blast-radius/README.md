# 0007 — Adaptive verification: scale review to blast radius, escalate on error rise

- **Date:** 2026-07-18
- **Issue:** Verjson/.github#33
- **PR:** Verjson/.github#35
- **Category:** AI governance / verification policy — sensitive-class
- **Relationship:** Extends and **partially supersedes ADR 0006** (its "never
  mutates gates" clause — see Decision §6)

## Context

We want to **reduce human eyeballing of AI work where AI is reliable and the
change is reversible**, and spend that saved attention only where it matters —
verification cost should scale with **blast radius, not uniformly**. The trigger
to tighten is a rise in errors (rework).

Phrased naively ("only eyeball when errors rise") that has two failure modes:

- **Lagging control.** Error-triggered review only tightens *after* bad code has
  merged. Fine for cheap, reversible categories; unacceptable for irreversible
  ones — the *first* error in auth or a migration can be a breach or data loss.
- **Blind spot.** You cannot detect a rise in errors in a category you have
  stopped looking at. Reverts catch loud failures; silently-wrong code produces
  no signal, and the dashboard reads a comforting 0% forever.

ADR 0006 established the rework telemetry as observe-and-report (it never mutates
gates). This ADR adds an **enforcement** layer while keeping that governance
intact: **humans own the policy and thresholds; the AI never re-rates its own
trust.**

## Decision

1. **Per-category verification tiers** (blast radius sets the floor):

   | Category | Default | Escalate to human when |
   |---|---|---|
   | docs, formatting, CI-caller swaps (reversible) | auto-merge, no eyeballing | rework-rate circuit breaker trips |
   | app / infra logic | AI-review + auto-merge | circuit breaker, or a canary spot-check fails |
   | auth/RBAC, migrations, secrets, IAM/OIDC, rulesets/branch protection, destructive | **human review — always** | n/a (never buys down) |

2. **Sensitive-class floor never buys down**, regardless of track record. On such
   PRs the AI **must pinpoint the exact file(s):line(s)** a human must eyeball —
   to make the mandatory review *fast*, not skippable.

3. **Error-triggered escalation is a human-configured circuit breaker** — a rate
   over a window with a minimum sample size and hysteresis/cooldown. It is
   automated *enforcement of a human-set rule*, not AI self-adjustment. The AI
   never loosens its own guardrails and never owns the thresholds.

4. **5% canary audit.** Even fully-auto-merge categories keep a random **5%**
   human-reviewed, to preserve an error signal — the price of safely not looking
   at the other 95%.

5. **Fail toward more review.** Low sample size, telemetry down, or thin coverage
   → default to *more* scrutiny. Absence of an error signal is not evidence of
   safety.

6. **Refines ADR 0006.** 0006 said the telemetry "never mutates merge or
   verification gates." This ADR narrows that: the system **may auto-escalate**
   per human-owned policy (tiers + circuit breaker). 0006's core principle is
   preserved unchanged — the AI does not re-rate its own trustworthiness and does
   not own the thresholds.

## Consequences

- Human attention concentrates on high-blast-radius, irreversible work; routine
  reversible work goes light-touch or unattended.
- The lagging-control blind spot is covered by the **canary** (§4); the
  conflict-of-interest and Goodhart hazards by human-owned thresholds + the
  sensitive floor (§2–3).
- Data-driven escalation depends on the #33 rework telemetry. Until that lands,
  the **tiers still apply by their human-set defaults** (docs auto, sensitive
  gated); only the automatic circuit-breaker escalation waits on the data.
- Every PR now carries a Verification + blast-radius / `file:line` block
  (operationalized via `PULL_REQUEST_TEMPLATE.md` in this PR).

## Follow-up

- Implement tiers, circuit breaker, and the 5% canary in Verjson/.github#33.
- Reflected as a global operating rule in the maintainer's agent config so the AI
  produces the pinpointed Verification block by default.
