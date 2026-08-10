#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/contract/scripts"
cp "$root/scripts/gen-container-candidate.sh" \
  "$root/scripts/container_release_manifest.py" \
  "$root/scripts/container_private_dependencies.py" \
  "$tmp/contract/scripts/"
git -C "$tmp/contract" init -q
git -C "$tmp/contract" config user.name fixture
git -C "$tmp/contract" config user.email fixture@example.invalid
git -C "$tmp/contract" add scripts
git -C "$tmp/contract" commit -qm fixture
ref="$(git -C "$tmp/contract" rev-parse HEAD)"
generator="$tmp/contract/scripts/gen-container-candidate.sh"

for fixture in single multi; do
  consumer="$tmp/$fixture"
  mkdir -p "$consumer/.github/workflows" "$consumer/scripts"
  "$generator" workflow "$ref" container-candidate.json \
    > "$consumer/.github/workflows/container-candidate.yml"
  "$generator" validator "$ref" container-candidate.json \
    > "$consumer/scripts/container_release_manifest.py"
  "$generator" contract-test "$ref" container-candidate.json \
    > "$consumer/scripts/container-candidate-contract.test.sh"
  chmod +x "$consumer/scripts/"*.sh "$consumer/scripts/"*.py
  cp "$root/scripts/fixtures/container-candidate/$fixture.json" "$consumer/container-candidate.json"
  jq -e '.images | length > 0' "$consumer/container-candidate.json" >/dev/null
  bash "$consumer/scripts/container-candidate-contract.test.sh"
  cp "$consumer/.github/workflows/container-candidate.yml" "$consumer/.github/workflows/container-candidate.yml.clean"
  sed -i 's/NODE_AUTH_TOKEN: \${{ secrets.NODE_AUTH_TOKEN }}/secrets: inherit/' "$consumer/.github/workflows/container-candidate.yml"
  if bash "$consumer/scripts/container-candidate-contract.test.sh" >/dev/null 2>&1; then
    echo "generated contract accepted credential-routing tampering" >&2
    exit 1
  fi
  mv "$consumer/.github/workflows/container-candidate.yml.clean" "$consumer/.github/workflows/container-candidate.yml"
done

workflow="$root/.github/workflows/container-candidate.yml"
python3 "$root/scripts/container_private_dependencies.test.py"
lifecycle="$tmp/lifecycle"
mkdir -p "$lifecycle/package"
cat > "$lifecycle/package/package.json" <<JSON
{"name":"lifecycle-probe","version":"1.0.0","scripts":{"postinstall":"touch $tmp/lifecycle-exfiltrated"}}
JSON
cat > "$lifecycle/package.json" <<'JSON'
{"name":"consumer","version":"1.0.0","dependencies":{"lifecycle-probe":"file:package"}}
JSON
npm install --prefix "$lifecycle" --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null
npm ci --prefix "$lifecycle" --ignore-scripts --no-audit --no-fund >/dev/null
[ ! -e "$tmp/lifecycle-exfiltrated" ] || { echo "npm lifecycle executed during credentialed acquisition" >&2; exit 1; }
grep -q "github.event_name == 'pull_request'" "$workflow"
grep -q "github.event_name == 'push'.*github.event.repository.default_branch" "$workflow"
grep -q 'packages: write' "$workflow"
grep -q 'id-token: write' "$workflow"
grep -q 'actions/attest-build-provenance@[0-9a-f]\{40\}' "$workflow"
grep -q 'commit identity already records a different digest' "$workflow"
grep -q 'imagetools create -t "\$commit_tag"' "$workflow"
if grep -q 'GITHUB_WORKFLOW_REF' "$workflow"; then
  echo "called workflows cannot prove their own pin through github.workflow_ref" >&2
  exit 1
fi
if awk '/^  pull-request-build:/{seen=1} /^  publish-base:/{seen=0} seen' "$workflow" | grep -Eq 'packages: write|id-token: write|docker/login-action|push: true'; then
  echo "pull-request build exposes a publication capability" >&2
  exit 1
fi
acquisition_job="$(awk '/^  acquire-private-node-dependencies:/{seen=1} /^  pull-request-build:/{seen=0} seen' "$workflow")"
grep -qF 'NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}' <<<"$acquisition_job"
grep -qF 'JOB_WORKFLOW_SHA: ${{ job.workflow_sha }}' "$workflow"
grep -qF '[ "$CONTRACT_REF" = "$JOB_WORKFLOW_SHA" ]' "$workflow"
grep -qF 'npm ci --ignore-scripts --no-audit --no-fund' <<<"$acquisition_job"
grep -qF 'NPM_CONFIG_USERCONFIG="$user_config"' <<<"$acquisition_job"
grep -qF 'NPM_CONFIG_GLOBALCONFIG="$global_config"' <<<"$acquisition_job"
grep -qF 'env -i \' <<<"$acquisition_job"
grep -qF 'if find . -name .npmrc -print -quit' <<<"$acquisition_job"
grep -qF 'git show "$BASE_SHA:$CONFIG_PATH"' <<<"$acquisition_job"
grep -qF '[ "$base_approved" = "$APPROVED_PRIVATE_PACKAGES" ]' <<<"$acquisition_job"
grep -qF 'npm ci --ignore-scripts' <<<"$acquisition_job"
! grep -Eq 'npm (install|run|exec|rebuild)|yarn|pnpm' <<<"$acquisition_job"
! grep -Eq 'subprocess|os\.system|extract(all)?\(' "$root/scripts/container_private_dependencies.py"
grep -qF 'container-node-modules-${{ github.run_id }}-${{ github.run_attempt }}-${{ steps.acquire.outputs.lock-digest }}' <<<"$acquisition_job"
for build_job in pull-request-build publish-base publish-derived; do
  build_block="$(awk -v start="  $build_job:" '
    $0 == start { seen=1; next }
    seen && /^  [A-Za-z0-9_.-]+:/ { exit }
    seen { print }
  ' "$workflow")"
  grep -qF 'build-contexts: verjson_node_modules=${{ runner.temp }}/container-node-modules-context' <<<"$build_block"
  grep -qF 'needs.acquire-private-node-dependencies.outputs.lock-digest' <<<"$build_block"
  grep -qF '.verjson-lock-sha256' <<<"$build_block"
  grep -qF "NODE_AUTH_TOKEN: ''" <<<"$build_block"
  grep -qF "ACTIONS_ID_TOKEN_REQUEST_TOKEN: ''" <<<"$build_block"
  if grep -Eq 'secrets\.|secret-envs:|^[[:space:]]+secrets:' <<<"$build_block"; then
    echo "$build_job exposes a credential to PR-controlled Docker execution" >&2
    exit 1
  fi
done
if grep -Eq 'uses: [^ ]+@(main|master|v[0-9]+)$' "$workflow"; then
  echo "container workflow contains an unpinned action" >&2
  exit 1
fi

before="$(sha256sum "$root/scripts/gen-changelog-caller.sh" "$root/.github/workflows/generated-artifacts.yml")"
"$generator" workflow "$ref" >/dev/null
after="$(sha256sum "$root/scripts/gen-changelog-caller.sh" "$root/.github/workflows/generated-artifacts.yml")"
[ "$before" = "$after" ] || { echo "container generator drifted changelog contract artifacts" >&2; exit 1; }
if "$generator" validator "$(printf 'a%.0s' {1..40})" >/dev/null 2>&1; then
  echo "candidate validator generation resolved a nonexistent pin from local files" >&2
  exit 1
fi

bash "$root/scripts/container-contract-coexistence.test.sh"

echo "container candidate canonical contract passed"
