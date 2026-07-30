# Allow read-only private check rollups — 2026-07-30

Grant the unprivileged, `ORG_ADMIN_TOKEN`-free merge gate `checks: read` so GitHub permits `statusCheckRollup` queries in private consumer repositories. Write access remains absent, `actions: write` stays isolated in the metadata-only dispatcher, and `ORG_ADMIN_TOKEN` never enters PR-controlled execution. See #240 and ADR 0037.
