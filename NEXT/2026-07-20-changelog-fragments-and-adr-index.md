# Changelog fragments + generated ADR index (kill the merge-conflict class) — 2026-07-20

Concurrent PRs used to conflict on every merge because each one prepended to a
shared `NEXT.md` and inserted a row in the shared `docs/decisions/README.md` ADR
table — during one fan-out round this forced three rebases of a single PR. This
removes that entire conflict class:

- **`NEXT.md` → `NEXT/` fragments.** Each entry is its own file
  `NEXT/YYYY-MM-DD-<slug>.md`; no PR edits a shared changelog, so the log can't
  conflict. `NEXT.md` is now a static pointer, prior history moved to
  `NEXT/0000-archive.md`, and `scripts/render-next.sh` renders the log newest-first
  on demand (nothing rendered is committed).
- **ADR index → generated.** `scripts/gen-adr-index.sh` rebuilds the table in
  `docs/decisions/README.md` (between markers) from each `NNNN-*/README.md`'s
  `# NNNN — Title` H1 + `**Date:**`. PRs add only their ADR directory; the table is
  derived, and `actions-ci` runs `--check` to fail on a stale table.
- Both checks wired into `actions-ci.yml` (path filters widened to `scripts/**`,
  `docs/decisions/**`, `NEXT/**`). Repo `CLAUDE.md` documents both conventions plus
  the autonomous-batch review process (open as draft / apply `hold` until the
  code-reviewer pass finishes, so the self-gate doesn't auto-merge mid-review).

First of the cost-reduction remedies; the AI-reviewer flake is tracked in #64.
