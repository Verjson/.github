# Self-gate runner lane must be redundant (ADR 0016) — 2026-07-20

The `Verjson/.github` self-gate lane (`runs-on: [self-hosted, meta]`, reserved in
#14 so pipeline-fix PRs never queue behind bulk/other-repo CI) runs on a **single**
`meta`-only runner, `gha-meta-1` — a SPOF: if it drops, `.github` PRs sit un-gated,
and a run's four gate jobs serialize on the one runner (observed congestion).
ADR 0016 decides the lane must be **redundant** (≥2 `meta`-only runners) and
`docs/runner-routing.md` is updated to match. Fix: provision a second dedicated
runner `gha-meta-2` as a **GCE** VM (also resolves private composite actions,
unlike `gha-meta-1`), registered `meta`-only and moved into the `GCP` group after
registration. **No workflow change** — `runs-on: [self-hosted, meta]` picks it up
automatically. Provisioning the VM is the runner-topology owner's on-box step,
tracked by #70. Sensitive-class (runner topology).
