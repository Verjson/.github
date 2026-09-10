# 0169 — Sealed environment App bootstrap

- **Status:** Accepted
- **Date:** 2026-09-10

## Context

[#1291](https://github.com/Verjson/.github/issues/1291) blocks the environment-bound App adoption in [#1285](https://github.com/Verjson/.github/issues/1285). The existing release, merge and review App private keys are available to trusted Actions runs, but the three main-only environments in `Verjson/.github` have no private-key secret. Copying plaintext through an operator machine or granting a runner an administrator credential would unnecessarily enlarge the trust boundary.

## Decision

Use a temporary, manually dispatched, protected-main bootstrap on a fresh GitHub-hosted Ubuntu 24.04 runner. The reviewed repository, three environment identities, sole main branch policies, public encryption keys and App mappings are fixed in `scripts/app-key-bootstrap-contract.json`; dispatch accepts no destinations or other inputs.

Before loading secrets into a single step, install the hash-locked Python 3.12 wheels for maintained PyNaCl 1.6.2 and its dependencies. PyNaCl's libsodium sealed boxes encrypt the existing values directly in memory with GitHub's environment public keys. This follows [PyNaCl's sealed-box contract](https://pynacl.readthedocs.io/en/latest/public/). `gh secret set --no-store --env` was considered, but fetching the environment public key from the runner would require permissions the offline encryption path does not need. No custom cryptography, administrator PAT, plaintext file, command argument or log is introduced. Retain only a one-day ciphertext artifact, bound to the fixed workflow, immutable source SHA, first run attempt, repository and destination contract.

An authenticated operator CLI performs the write. It checks that its implementation exactly matches the reviewed main ancestor, validates the successful workflow registration/run and artifact origin/digest, and rechecks all environment IDs, main-only policy identities and public keys. Immediately before each fixed ciphertext PUT it rechecks that destination and refuses to replace an existing secret. GitHub provides no conditional create/CAS for this endpoint: an administrator changing a destination between GET and PUT remains a residual race. Run one importer at a time and exclude concurrent environment administration during this brief operation.

Write a metadata receipt before each PUT, marking uncertain outcomes before crossing the boundary. Never automatically retry an uncertain write or overwrite an existing value. A successful metadata readback records the environment identity and secret update time. A subsequent, separately dispatched pinned-main verification run must start strictly after every successful readback's secret update time. Its three explicit environment jobs use the expected client IDs, each mint a contents-read token restricted to `.github`, and check the App slug, installation ID and actual selected repository list. Local verification requires all three successful provisioning receipts, unchanged environment metadata and all three successful proof jobs. Because the exact environment secret exists before that run, environment precedence prevents org-secret fallback from being accepted as migration proof.

Scope is `.github` self-adoption only. Keep all broader copies until a separately reviewed consumer/shared-required-workflow cohort has migrated. Retire the bootstrap workflows, crypto lock and migration-only tooling after successful migration; retain ciphertext and metadata receipts. No automatic org-secret withdrawal or general-purpose secret migration service is authorized.

## Operation and recovery

Follow [the bootstrap runbook](../../app-key-bootstrap-runbook.md). Independent code/security review and green CI precede dispatch. The root operator owns live provisioning and verification. A stale/rotated key or policy mismatch requires a newly reviewed contract and new sealed run, never relaxation of validation. An incomplete receipt requires inspection of the affected environment's public secret metadata before deciding whether any untouched roles can proceed with a new receipt.

## Consequences

The runner never receives environment administration authority. The operator never receives plaintext App keys. Reviewed public metadata intentionally couples this temporary operation to the three concrete destinations: rotation requires review rather than dispatcher flexibility. The temporary crypto dependency is acceptable for this bounded migration and is retired with it.
