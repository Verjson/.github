# Protected runner deployment operations

The deployment contract is a separately dispatched transition from an immutable
release manifest to an existing DigitalOcean runner fleet. It never builds an image,
creates capacity, resizes a Droplet, or accepts a tag. Live adoption and fleet-specific
values belong in the consumer repository; this repository stores no deployment token.

## Generate the adopter contract

Acquire `scripts/gen-container-deployment.sh` from one reviewed 40-character
`Verjson/.github` commit and generate all five artifacts at that same commit:

```sh
scripts/gen-container-deployment.sh workflow <contract-sha> container-deployment.json > .github/workflows/container-deployment.yml
scripts/gen-container-deployment.sh controller <contract-sha> > scripts/container_deployment_controller.py
scripts/gen-container-deployment.sh preflight <contract-sha> > scripts/container_deployment_preflight.py
scripts/gen-container-deployment.sh receipt-schema <contract-sha> > scripts/deployment-receipt.schema.json
scripts/gen-container-deployment.sh contract-test <contract-sha> container-deployment.json > scripts/container-deployment-contract.test.sh
```

Commit a reviewed `container-deployment.json`. Its fleet selector fixes the existing
lane, project, ordinary canary, deterministic runner inventory, minimum available
capacity, time bounds, runner group, labels, tools, and consumer-owned evidence/probe
scripts. The local CLI command is exactly `npx --no-install verjson-cloud`; generation
does not install or select a mutable CLI. Run the generated contract test in CI.

Configure the consumer's `production` environment to admit protected branches only,
require an independent reviewer, prevent self-review, and disable administrator bypass.
Store the narrowly scoped `VERJSON_RUNNER_DEPLOY_TOKEN` only there. Review those settings
and credential scope as sensitive changes; never print their values.

## Dry-run and deployment

Dispatch with `dry-run: true` first. The unprotected dry-run resolves the immutable
manifest and prints the exact canary-first host order without receiving a deployment
credential or mutating an external system. Reject any plan with an unexpected host,
baseline, signer, source ref, release-contract pin, label/tool requirement, or capacity
floor.

Dispatch the same manifest digest and fleet selector with `dry-run: false`. The job waits
at `production`, re-collects current evidence, retains revision `0000` before the first
mutation, then calls `verjson-cloud runner update --only <host>` one host at a time. The
canary's exact routed probe and observation window must pass before a second host starts.
Every later revision binds the canonical digest of its predecessor.

## Pause, resume, and interruption

Do not cancel a healthy update merely because the observation window is quiet. To pause
before dispatch, retain the dry-run plan and do not approve `production`. Once mutation
has started, a failed drain, admission check, probe, timeout, or operator cancellation
stops the state machine; it never skips to another host.

An interrupted run retains at least its admitted revision. Seal an `interrupted` revision
from that exact attempt before recovery. Resume only when the current fleet agrees with
the recorded completed transitions and untouched baseline. Supply the latest retained
receipt so the controller skips already verified hosts; never restart from a guessed
host or mutable tag.

## Rollback

Rollback is a new, independently approved `production` dispatch with `action: rollback`.
Select the exact manifest identity recorded as `observedDeployedRelease` on the failed or
interrupted attempt and supply that attempt's retained canonical receipt digest. The
consumer evidence adapter retrieves the retained receipt by that identity; it is never a
dispatcher-controlled filesystem path. The controller rejects a
predecessor from another attempt, a changed baseline, or a receipt-digest mismatch. The
same canary, sequential capacity floor, probes, and admission checks apply. If the exact
baseline manifest or evidence is unavailable, stop and escalate; do not rebuild or use a
tag as recovery authority.

## Credential rotation and incidents

Rotate `VERJSON_RUNNER_DEPLOY_TOKEN` in the consumer environment without editing callers
or generated files. Confirm the replacement retains only the named existing-fleet update,
runner admission, and evidence permissions; it must not authorize capacity creation or
unrelated environments. Revoke the old credential after a mutation-free dry-run and a
reviewed environment audit.

For signer, digest, fleet-baseline, transaction-lock, capacity, or rollback-verification
failures, preserve all receipt artifacts and the workflow URL, quarantine the affected
runner from scheduling, and escalate to the runner-fleet owner and security owner. Do not
retry until the retained receipt and live state explain every host. Never include secret
or organization-variable values in an incident record.
