# ai-review gate — drop the unused `id-token: write` permission — 2026-07-22

The `ai-review-merge.yml` gate job declared `id-token: write`, but nothing in the
workflow mints an OIDC token — there is no `google-github-actions/auth`,
`aws-actions/configure-aws-credentials`, `azure/login`, or `getIDToken()` consumer
(the only `OIDC` string is inside the reviewer prompt's sensitive-class list). The
permission was dead grant. Removed it so the gate job's token is least-privilege
(`contents: read` + `pull-requests`/`issues: write` + `actions: read`). No behaviour
change. Surfaced by tequity's autonomous review (tequityapp/tequity-api#33,
tequityapp/tequity-ui#17); the tequityapp copies get the same drop on re-sync.
