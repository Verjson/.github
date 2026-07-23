# ci-gate extraction tests run under `bash -eo pipefail` — 2026-07-22

The ci-gate extraction tests executed the extracted workflow block with plain
`bash` (no `-e`), so a step that aborts under GitHub's real `run:` shell
(`bash --noprofile --norc -eo pipefail`) could pass its test yet fail in
production — exactly how #124 (the org-wide merge outage) shipped. Swept the
remaining seven harnesses (dispatch-target-guard, followup-issues, freshness,
hold, node-ci-db-service, preflight-timing, review-comment) to invoke the block
under `bash -eo pipefail`, matching GitHub. All still pass — no other latent
fail-closed-abort surfaced; the class check is now in place. Ref #126, #124.
