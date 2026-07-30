# Route Verjson workflows through online general runners — 2026-07-30

All Verjson-owned workflow defaults and repository-local jobs now target the
provider-neutral `general` lane so required checks do not queue behind offline
provider or isolation labels. External reusable callers keep their hosted
default, and #204 tracks restoration of the paused isolation hardening. Fixes
#212.
