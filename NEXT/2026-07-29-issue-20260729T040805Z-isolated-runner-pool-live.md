---
date: 2026-07-29
id: 20260729T040805Z
title: Permanent isolated runner pool live
---

The standing `isolated` pool required by #173 (and assumed by the ADR 0030
routing merged in #175) is deployed: org runner group `isolated` (id 6,
`visibility: selected`, public repos allowed) granted to `.github`,
`verjson-cli`, `verjson-cli-cloud`, and `verjson-cli-project-init`; Spot MIG
`isolated` (us-east4, 3 × n1-standard-1, template `isolated-tmpl-cd0b6286`)
in `verjson-ci-502400` via released `@verjson/cli-cloud` 0.25.1
(`--runner-mode isolated-pr`), image pinned to the canary-proven digest
`ghcr.io/verjson/gha-runner@sha256:d1ff3e93d7cd694229842fb958c61d789dde34b0b34cc6baf058bdbff89fa125`
(`base-d1c4376`), not the pre-contract `b2cb8c3e` digest
(Verjson/verjson-cli-cloud#161). Lane SA `runner-isolated@…` holds
`secretAccessor` on `gha-runner-reg-key` only. NAT adoption still needs the
local matcher shim for Verjson/verjson-cli-cloud#157. Live admission receipts
confirm `metadata_denied=true socket_absent=true shared_writes=false` and
per-job child teardown; deployment evidence on #173.
