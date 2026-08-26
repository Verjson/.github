---
date: 2026-08-25
issue: 1086
title: Fail AI authorization slug drift closed without stranded checks
impact: patch
---

Record the canonical CI Apps' organization-neutral live identities and make the AI
authorization arm reject a missing, malformed, or mismatched token-action App slug
before creating an authorization check. Remove an invalid installation-token
`GET /installation` probe after a production 404 proved that endpoint is unavailable to
the legitimate credential. Export each created check ID before validating its returned
App attribution so the no-dispatch terminalizer can complete any mismatch as failure.
