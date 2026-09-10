# Reusable environment secret context probe — retired

After #1289 merged at `1664d518c13f207916f793b3218bee545209b8ee`, [rearm run 34431240566](https://github.com/Verjson/.github/actions/runs/34431240566) passed the main-only policy prerequisite but the App mint received an empty key. The environment key metadata and earlier direct-job expected-App proof were valid. [Upstream runner issue 4453](https://github.com/actions/runner/issues/4453) reports the same reusable environment resolution failure; [GitHub's reusable workflow documentation](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows#using-inputs-and-secrets-in-a-reusable-workflow) describes environment precedence but does not prove that an undeclared, ungranted secret resolves at runtime.

This temporary probe diagnoses #1285 without changing production callers, real keys or environment policy. The operator provisioned the random noncredential `APP_KEY_CONTEXT_PROBE` only in `.github`'s existing `ai-review-app` environment at `2026-09-10T03:02:51Z`, after checking that no same-name broader secret exists. No probe value is retained locally or printed.

The manually dispatched caller invokes four cases at the same reviewed commit:

| Case | Callee declaration | Caller grant |
| --- | --- | --- |
| undeclared | None | None |
| declared | Optional exact probe name | None |
| explicit-empty | Optional exact probe name | Literal empty string |
| inherited | None | `secrets: inherit` |

Both callees have identical fixed `ai-review-app` jobs on fresh GitHub-hosted runners. They have no token permissions, checkout, actions, minting or real App-key references. The only shell command reports `populated=true` or `populated=false`, never a value or length. The inherited case necessarily makes broader caller secrets available to that reviewed job; its fixed source never references them. This is a bounded diagnostic exception, not authorization to inherit secrets in operational callers.

After independent review and green CI, the operator merges this probe, dispatches `app-key-context-probe.yml` on main and records the exact head/run/first attempt plus all four boolean results. Confirm current environment-only probe metadata and absence of broader same-name copies again before interpreting results. A populated result with an absent or literal-empty caller grant demonstrates environment resolution without forwarding a broad value. No result is claimed before this runtime test.

For the non-main control, use only an exact reviewed source copy on a temporary operator-owned branch and verify its SHA before dispatch. Existing main-only native policy must deny all four callee jobs before a runner/step starts. Record explicit denial evidence, not merely workflow failure. Do not relax the policy or add a bypass. Remove the temporary branch after checking its SHA.

Use the observations to select the narrowest supported production fix in a separately reviewed change. Retire these three workflows, two exact hosted-inventory sites, test registration and probe-only test after the result is recorded; the operator then removes the noncredential environment probe. Preserve this record and run URLs. Broad App copies and the protective shared-workflow pin remain unchanged.

## Recorded result and retirement

At immutable source [`a5b55fbfb07d433b0ed7e07b36424ba710ee9062`](https://github.com/Verjson/.github/tree/a5b55fbfb07d433b0ed7e07b36424ba710ee9062), [main run 34433194313](https://github.com/Verjson/.github/actions/runs/34433194313) returned false for undeclared, declared and explicit-empty, and true only for inherited. [Non-main run 34433211907](https://github.com/Verjson/.github/actions/runs/34433211907) denied all four jobs natively, with zero runners/steps. The [receipt](https://github.com/Verjson/.github/issues/1285#issuecomment-5612184570) records the metadata controls.

ADR 0171 selects the proven inherited transport. The three workflows, probe-only test/CI registration and two hosted routing sites are removed in that correction. Earlier instructions above document the historical protocol, not an available dispatch surface. The operator removes the noncredential sentinel after the operational proof; no broader App copy or environment policy is changed by probe retirement.
