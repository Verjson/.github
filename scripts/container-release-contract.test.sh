#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/contract/scripts" "$tmp/consumer/.github/workflows" "$tmp/consumer/scripts"
cp "$root/scripts/gen-container-release.sh" "$root/scripts/container_release_promotion.py" "$root/scripts/container_release_manifest.py" "$root/scripts/container_artifact_extract.py" "$root/scripts/container_attestation_verify.py" "$tmp/contract/scripts/"
git -C "$tmp/contract" init -q; git -C "$tmp/contract" config user.name fixture; git -C "$tmp/contract" config user.email fixture@example.invalid
git -C "$tmp/contract" add scripts; git -C "$tmp/contract" commit -qm fixture; ref="$(git -C "$tmp/contract" rev-parse HEAD)"
generator="$tmp/contract/scripts/gen-container-release.sh"
"$generator" workflow "$ref" >"$tmp/consumer/.github/workflows/container-release.yml"
"$generator" validator "$ref" >"$tmp/consumer/scripts/container_release_promotion.py"
"$generator" manifest-validator "$ref" >"$tmp/consumer/scripts/container_release_manifest.py"
"$generator" artifact-extractor "$ref" >"$tmp/consumer/scripts/container_artifact_extract.py"
"$generator" attestation-verifier "$ref" >"$tmp/consumer/scripts/container_attestation_verify.py"
"$generator" contract-test "$ref" >"$tmp/consumer/scripts/container-release-contract.test.sh"
(cd "$tmp/consumer" && bash scripts/container-release-contract.test.sh)
if "$generator" validator "$(printf 'a%.0s' {1..40})" >/dev/null 2>&1; then
  echo "validator generation resolved a nonexistent pin from local files" >&2; exit 1
fi
if "$generator" workflow "$ref" ../hostile.json >/dev/null 2>&1; then
  echo "generator accepted a config path outside the source commit" >&2; exit 1
fi
workflow="$root/.github/workflows/container-release.yml"
grep -q "github.event_name == 'workflow_dispatch'" "$workflow"
! grep -Eq '^  (push|pull_request):' "$workflow"
grep -q 'imagetools create' "$workflow"
! grep -Eq 'build-push-action|docker build|deploy|verjson-cli-cloud' "$workflow"
grep -q 'admin-scoped release credential required' "$workflow"
grep -q 'git push --atomic' "$workflow"
grep -q 'docker/login-action@' "$workflow"
grep -A5 'docker/login-action@' "$workflow" | grep -q 'secrets.release-token'
grep -q 'gh attestation verify' "$workflow"
grep -q 'container_attestation_verify.py' "$workflow"
grep -q 'actions/attest-build-provenance@' "$workflow"
grep -q 'container-release-${{ github.repository }}-${{ inputs.version }}' "$workflow"
grep -q 'complete stable alias set diverged' "$workflow"
grep -q 'continue-on-error: true' "$workflow"
grep -q 'package_retention.py' "$workflow"
grep -q 'packages: write' "$workflow"
grep -q 'needs: promote' "$workflow"
grep -q 'retention-targets' "$workflow"
grep -q 'container_artifact_extract.py candidate.zip candidate.json' "$workflow"
grep -Fq 'candidate_artifact_digest="${BASH_REMATCH[2]}"' "$workflow"
! grep -Fq 'candidate_artifact_digest="${BASH_REMATCH[1]}"' "$workflow"
grep -q 'existing tag records a divergent release manifest' "$workflow"
grep -q 'existing GitHub Release manifest diverges' "$workflow"
bash "$root/scripts/container-contract-coexistence.test.sh"
echo 'container release canonical contract passed'
