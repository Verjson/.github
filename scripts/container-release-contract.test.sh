#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/contract/scripts" "$tmp/consumer/.github/workflows" "$tmp/consumer/scripts"
cp "$root/scripts/gen-container-release.sh" "$root/scripts/changelog.py" "$root/scripts/container_release_promotion.py" "$root/scripts/container_release_manifest.py" "$root/scripts/container_artifact_extract.py" "$root/scripts/container_attestation_verify.py" "$tmp/contract/scripts/"
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
mkdir -p "$tmp/consumer/NEXT"
cat >"$tmp/consumer/NEXT/2026-08-24-issue-1013-clean-adopter.md" <<'EOF'
---
date: 2026-08-24
issue: 1013
impact: major
title: Exercise a clean generated container release adopter
---

Release-path fixture.
EOF
git -C "$tmp/consumer" init -q
git -C "$tmp/consumer" config user.name fixture
git -C "$tmp/consumer" config user.email fixture@example.invalid
git -C "$tmp/consumer" add .
git -C "$tmp/consumer" commit -qm fixture
mkdir -p "$tmp/consumer/.container-release-contract/scripts"
git -C "$tmp/contract" show "$ref:scripts/changelog.py" >"$tmp/consumer/.container-release-contract/scripts/changelog.py"
(cd "$tmp/consumer" && python .container-release-contract/scripts/changelog.py release --version v1.0.0)
test -f "$tmp/consumer/CHANGELOG/v1.0.0.md"
test "$(git -C "$tmp/consumer" tag --list)" = v1.0.0
test ! -e "$tmp/consumer/scripts/changelog.py"
cp "$tmp/consumer/.github/workflows/container-release.yml" "$tmp/workflow.clean"
reject_caller_mutation() {
  if (cd "$tmp/consumer" && bash scripts/container-release-contract.test.sh >/dev/null 2>&1); then
    echo "generated contract accepted caller drift: $1" >&2
    exit 1
  fi
  cp "$tmp/workflow.clean" "$tmp/consumer/.github/workflows/container-release.yml"
}
sed -i 's/^  packages: write$/  packages: read/' "$tmp/consumer/.github/workflows/container-release.yml"
reject_caller_mutation 'package permission'
sed -i 's/vars.RELEASE_APP_CLIENT_ID/vars.OTHER_CLIENT_ID/' "$tmp/consumer/.github/workflows/container-release.yml"
reject_caller_mutation 'App client ID mapping'
sed -i 's/secrets.RELEASE_APP_PRIVATE_KEY/secrets.OTHER_PRIVATE_KEY/' "$tmp/consumer/.github/workflows/container-release.yml"
reject_caller_mutation 'App private-key mapping'
sed -i '/^    secrets:/,$c\    secrets: inherit' "$tmp/consumer/.github/workflows/container-release.yml"
reject_caller_mutation 'inherited secrets'
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
grep -q 'Mint exact-repository release App token' "$workflow"
grep -q 'git push --atomic' "$workflow"
grep -q 'docker/login-action@' "$workflow"
! grep -q 'secrets.release-token' "$workflow"
legacy_release_token='RELEASE_'"TOKEN"
legacy_org_release_token='VERJSON_RELEASE_'"TOKEN"
! grep -Eq "$legacy_release_token|$legacy_org_release_token" "$workflow"
grep -q 'gh attestation verify' "$workflow"
grep -q 'container_attestation_verify.py' "$workflow"
grep -q 'repository: Verjson/.github' "$workflow"
grep -q 'ref: \${{ inputs.contract-ref }}' "$workflow"
grep -q 'python .container-release-contract/scripts/changelog.py release' "$workflow"
! grep -q 'python scripts/changelog.py release' "$workflow"
grep -q 'actions/attest-build-provenance@' "$workflow"
! grep -q 'container-release-${{ github.repository }}-${{ inputs.version }}' "$workflow"
grep -q 'group: container-release-${{ github.repository }}' "$workflow"
grep -q 'complete stable alias set diverged' "$workflow"
grep -q 'continue-on-error: true' "$workflow"
grep -q 'package_retention.py' "$workflow"
grep -q 'packages: write' "$workflow"
grep -q 'needs: promote' "$workflow"
grep -q 'retention-targets' "$workflow"
grep -q 'Validate the immutable retention contract ref' "$workflow"
grep -q '\^\[0-9a-f\]{40}\$' "$workflow"
guard_line="$(grep -n 'Validate the immutable retention contract ref' "$workflow" | tail -1 | cut -d: -f1)"
checkout_line="$(grep -n 'path: .package-retention-contract' "$workflow" | cut -d: -f1)"
[ "$guard_line" -lt "$checkout_line" ]
grep -q 'container_artifact_extract.py candidate.zip candidate.json' "$workflow"
grep -Fq 'candidate_artifact_digest="${BASH_REMATCH[2]}"' "$workflow"
! grep -Fq 'candidate_artifact_digest="${BASH_REMATCH[1]}"' "$workflow"
grep -q 'existing tag records a divergent release manifest' "$workflow"
grep -q 'existing GitHub Release manifest diverges' "$workflow"
bash "$root/scripts/container-contract-coexistence.test.sh"
echo 'container release canonical contract passed'
