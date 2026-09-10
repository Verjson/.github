# Environment App key bootstrap — retired

The temporary bootstrap completed its three-environment migration and is retired by the `.github` self-adoption change for [#1285](https://github.com/Verjson/.github/issues/1285). Both dispatch workflows, migration executable/configuration/dependency files, tests and their routing/CI registrations have been removed.

[ADR 0169](decisions/0169-sealed-environment-app-bootstrap/README.md) remains the immutable decision record. The [live provisioning and proof receipt](https://github.com/Verjson/.github/issues/1291#issuecomment-5611815789) records sealing run `34429861784`, ciphertext artifact `10134051852`, successful environment metadata readbacks and proof run `34429989792`. All three expected Apps minted tokens restricted to `.github`; the local verifier exited 0.

The exact migration source and original procedure remain available at immutable commit [`0169a10ca6b96b58f1a23ce724461edee1e724bb`](https://github.com/Verjson/.github/tree/0169a10ca6b96b58f1a23ce724461edee1e724bb). Historical inspection uses an isolated checkout of that commit and the retained ciphertext/metadata receipts. Its live verifier deliberately requires fresh runs and current environment metadata, so an old receipt is historical evidence, not a newly executable verification claim. Do not redispatch the retired bootstrap or reapply old ciphertext.

The operator retained ciphertext and metadata outside the one-day Actions artifact lifetime. No plaintext key or token belongs in these records. Broader secret copies and the protective shared-workflow pin remain until the separately prepared cohort rollout in [the environment-key runbook](app-key-environment-rollout.md).
