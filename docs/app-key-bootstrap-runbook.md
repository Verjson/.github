# Environment App key bootstrap

This temporary procedure implements [ADR 0169](decisions/0169-sealed-environment-app-bootstrap/README.md) and [#1291](https://github.com/Verjson/.github/issues/1291). It provisions only `.github`'s `release-app`, `merge-app` and `ai-review-app` environments. No org or repository secret is removed.

1. Complete independent review, merge with green CI, and use an isolated checkout of that exact main commit. Confirm no concurrent environment administrator or importer is active. Retain the reviewed immutable SHA.
2. Dispatch `app-key-bootstrap.yml` on `main` with no inputs. Require its first attempt to succeed. Do not rerun a failed attempt: diagnose and dispatch a new run if appropriate. Artifact lifetime is one day.
3. From the exact reviewed checkout, use the operator's existing authenticated `gh` session. The script validates its local source against the supplied commit, verifies origin and the ciphertext archive digest, and checks fresh destination identities/policies/keys before importing:

   ```sh
   python3 scripts/app-key-bootstrap.py apply --source-sha "$reviewed_sha" --run-id "$seal_run_id" --receipt "$receipt_path"
   ```

   Choose a new local receipt path in an operator-owned directory. The receipt contains only metadata. Never overwrite it or blindly repeat a failed invocation. An `uncertain` role means a PUT may have succeeded: inspect public destination secret metadata before recovery. `--role release`, `--role merge`, or `--role review` can select untouched roles with a new receipt; existing secrets are always refused. The importer is not a concurrent administration lock, and GitHub's endpoint has no conditional create.
4. Only after all three imports/readbacks succeed, dispatch `app-key-bootstrap-verify.yml` on the same reviewed main SHA (the dispatcher ref is `main`; verify that its head is the reviewed SHA). Its three jobs explicitly bind their environment and expected App client ID. Each token is revoked by the pinned token action's post step.
5. Validate the successful proof run against every successful provisioning receipt:

   ```sh
   python3 scripts/app-key-bootstrap.py verify --source-sha "$reviewed_sha" --run-id "$verify_run_id" --receipt "$receipt_path"
   ```

   Repeat `--receipt` only for distinct partial provisioning receipts covering all three roles. The proof must have started after every imported secret update; unchanged secret metadata and successful expected-App/repository-scope jobs are mandatory. A green run alone is insufficient.
6. Retain ciphertext and metadata receipts, complete `.github` self-adoption, and remove the temporary bootstrap surface through a reviewed follow-up PR. Keep broader copies for the separately prepared consumer cohort.

No command should print a private key or token. API failures intentionally emit a generic safe error. Diagnose from public workflow/artifact/environment metadata and the local partial receipt, never by enabling shell tracing or secret diagnostics.
