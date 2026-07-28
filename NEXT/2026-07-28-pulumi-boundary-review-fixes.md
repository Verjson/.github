# Close Pulumi validation runner and admission leaks — 2026-07-28

Pinned credential-free validation to the GitHub-hosted `ubuntu-24.04` image and
reduced preview admission inputs to boolean secret-presence flags. Callers can
no longer route validation commands onto a runner with ambient credentials, and
the admission job never receives raw cloud secret values (#151; ADR 0027).
