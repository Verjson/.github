# Pin nested Node workflow actions and release tooling — 2026-07-21

Pin checkout and setup-node in both reusable Node workflows to audited v7 commit
SHAs, and replace runtime `npx` resolution with semantic-release 25.0.8 installed
from a lockfile checked out at the reusable job's own workflow commit. Renovate
now maintains the action digests and npm lock, with CI guarding the immutable
and vulnerability-free production graph. Addresses #89; initial `v1` release
bootstrap remains tracked separately in #85.
