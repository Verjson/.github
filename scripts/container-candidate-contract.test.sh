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
  cp "$consumer/.github/workflows/container-candidate.yml" "$consumer/.github/workflows/container-candidate.yml.clean"
  sed -i '/^  actions: read$/d' "$consumer/.github/workflows/container-candidate.yml"
  if bash "$consumer/scripts/container-candidate-contract.test.sh" >/dev/null 2>&1; then
    echo "generated contract accepted an unsatisfied reusable Actions permission" >&2
    exit 1
  fi
  mv "$consumer/.github/workflows/container-candidate.yml.clean" "$consumer/.github/workflows/container-candidate.yml"
done

workflow="$root/.github/workflows/container-candidate.yml"
canary="$root/.github/workflows/container-candidate-reusable-contract.yml"
CALLER_WORKFLOW="$tmp/single/.github/workflows/container-candidate.yml" \
CALLEE_WORKFLOW="$workflow" CANARY_WORKFLOW="$canary" python3 - <<'PY'
import os

import yaml


with open(os.environ["CALLER_WORKFLOW"], encoding="utf-8") as stream:
    caller = yaml.safe_load(stream)
with open(os.environ["CALLEE_WORKFLOW"], encoding="utf-8") as stream:
    callee = yaml.safe_load(stream)
with open(os.environ["CANARY_WORKFLOW"], encoding="utf-8") as stream:
    canary = yaml.safe_load(stream)

caller_permissions = caller["permissions"]
expected = {
    "actions": "read",
    "attestations": "write",
    "contents": "read",
    "packages": "write",
    "id-token": "write",
}
assert caller_permissions == expected, "generated caller permissions are not exact"
levels = {None: 0, "none": 0, "read": 1, "write": 2}
default_permissions = callee.get("permissions", {})
for job_name, job in callee["jobs"].items():
    requested = job.get("permissions", default_permissions)
    for permission, level in requested.items():
        assert permission in caller_permissions, f"caller omits {job_name} permission {permission}"
        assert levels[level] <= levels[caller_permissions[permission]], (
            f"caller cannot satisfy {job_name} permission {permission}: {level}"
        )
assert canary["jobs"]["candidate"]["with"]["runner"] == '"ubuntu-24.04"', (
    "reusable-call canary must use a JSON-encoded GitHub-hosted runner"
)
PY
python3 "$root/scripts/container_private_dependencies.test.py"
python3 "$root/scripts/container_oci_index.test.py"
[ "$(jq -r '((.privateNodePackages // []) | length > 0)' "$root/scripts/fixtures/container-candidate/single.json")" = false ]
private_config="$tmp/private-container-candidate.json"
jq '.privateNodePackages = ["@verjson/private-package"]' \
  "$root/scripts/fixtures/container-candidate/single.json" >"$private_config"
[ "$(jq -r '((.privateNodePackages // []) | length > 0)' "$private_config")" = true ]

prepare_script="$tmp/prepare-config.sh"
extract_config_run() {
  local source=$1
  local destination=$2

  if ! awk '
    function fail(message) {
      print message > "/dev/stderr"
      failed = 1
      exit 1
    }

    in_script && /^          / {
      sub(/^          /, "")
      print
      if ($0 !~ /^[[:space:]]*$/) found_body = 1
      next
    }
    in_script && /^ *$/ { print ""; next }
    in_script { exit }

    $0 == "  prepare:" {
      found_prepare = 1
      in_prepare = 1
      next
    }
    in_prepare && /^  [A-Za-z0-9_.-]+:/ {
      fail("prepare job ended before its config run block")
    }
    in_prepare && $0 == "      - id: config" {
      if (found_step) fail("prepare job contains multiple config steps")
      found_step = 1
      in_step = 1
      next
    }
    in_step && /^      - / { fail("config step is missing a run block") }
    in_step && /^        run:/ {
      if ($0 != "        run: |") {
        fail("config step run block is not a literal block")
      }
      found_run = 1
      in_step = 0
      in_script = 1
      next
    }

    END {
      if (failed) exit 1
      if (!found_prepare) fail("prepare job is missing")
      if (!found_step) fail("config step is missing")
      if (!found_run) fail("config step is missing a run block")
      if (!found_body) fail("config step run block is empty")
    }
  ' "$source" >"$destination"; then
    rm -f "$destination"
    return 1
  fi
}

extraction_fixture="$tmp/config-step.yml"
cat >"$extraction_fixture" <<'YAML'
jobs:
  prepare:
    steps:
      - id: config
        name: Prepare candidate configuration
        shell: bash
        env:
          OPTIONAL_KEY: present
        run: |
          printf 'config\n' >"$EXTRACTION_MARKER"
      - name: Unrelated step
        run: |
          printf 'unrelated\n' >"$EXTRACTION_MARKER"
YAML
extracted_fixture_script="$tmp/extracted-config-step.sh"
extract_config_run "$extraction_fixture" "$extracted_fixture_script"
extraction_marker="$tmp/extraction-marker"
EXTRACTION_MARKER="$extraction_marker" bash "$extracted_fixture_script"
grep -qx config "$extraction_marker"

missing_run_fixture="$tmp/config-step-missing-run.yml"
cat >"$missing_run_fixture" <<'YAML'
jobs:
  prepare:
    steps:
      - id: config
        name: Missing run block
  later:
    steps:
      - id: config
        run: |
          exit 0
YAML
if extract_config_run "$missing_run_fixture" "$tmp/missing-run.sh" 2>/dev/null; then
  echo "config extraction accepted a missing run block" >&2
  exit 1
fi

malformed_run_fixture="$tmp/config-step-malformed-run.yml"
cat >"$malformed_run_fixture" <<'YAML'
jobs:
  prepare:
    steps:
      - id: config
        shell: bash
        run: >
          exit 0
YAML
if extract_config_run "$malformed_run_fixture" "$tmp/malformed-run.sh" 2>/dev/null; then
  echo "config extraction accepted a malformed run block" >&2
  exit 1
fi

empty_run_fixture="$tmp/config-step-empty-run.yml"
cat >"$empty_run_fixture" <<'YAML'
jobs:
  prepare:
    steps:
      - id: config
        run: |

YAML
if extract_config_run "$empty_run_fixture" "$tmp/empty-run.sh" 2>/dev/null; then
  echo "config extraction accepted an empty run block" >&2
  exit 1
fi

blank_line_fixture="$tmp/config-step-blank-line.yml"
printf '%s\n' \
  'jobs:' \
  '  prepare:' \
  '    steps:' \
  '      - id: config' \
  '        run: |' \
  '          printf '\''before\n'\'' >"$EXTRACTION_MARKER"' \
  '        ' \
  '          printf '\''after\n'\'' >>"$EXTRACTION_MARKER"' \
  >"$blank_line_fixture"
blank_line_script="$tmp/config-step-blank-line.sh"
extract_config_run "$blank_line_fixture" "$blank_line_script"
blank_line_marker="$tmp/config-step-blank-line-marker"
EXTRACTION_MARKER="$blank_line_marker" bash "$blank_line_script"
[ "$(sed -n '1p' "$blank_line_marker")" = before ]
[ "$(sed -n '2p' "$blank_line_marker")" = after ]

extract_config_run "$workflow" "$prepare_script"
bash -n "$prepare_script"
first_adoption="$tmp/first-adoption"
mkdir -p "$first_adoption"
git -C "$first_adoption" init -q
git -C "$first_adoption" config user.name fixture
git -C "$first_adoption" config user.email fixture@example.invalid
printf 'base\n' >"$first_adoption/README.md"
git -C "$first_adoption" add README.md
git -C "$first_adoption" commit -qm base-without-container-config
first_adoption_base="$(git -C "$first_adoption" rev-parse HEAD)"
cp "$root/scripts/fixtures/container-candidate/single.json" \
  "$first_adoption/container-candidate.json"
git -C "$first_adoption" add container-candidate.json
git -C "$first_adoption" commit -qm add-container-config
[ ! -e "$first_adoption/package-lock.json" ]
if git -C "$first_adoption" cat-file -e "$first_adoption_base:container-candidate.json" 2>/dev/null; then
  echo "first-adoption fixture unexpectedly has candidate config on its base" >&2
  exit 1
fi
first_adoption_output="$tmp/first-adoption-output"
(
  cd "$first_adoption"
  CONFIG_PATH=container-candidate.json \
    CONTRACT_REF="$ref" \
    GITHUB_OUTPUT="$first_adoption_output" \
    GITHUB_REPOSITORY=Verjson/example \
    GITHUB_REPOSITORY_OWNER=Verjson \
    GITHUB_RUN_ATTEMPT=1 \
    GITHUB_RUN_ID=12345 \
    JOB_WORKFLOW_SHA="$ref" \
    bash "$prepare_script"
)
grep -qx 'has-private-node-packages=false' "$first_adoption_output"

run_invalid_config() {
  local config_path=$1
  local output=$2

  if (
    cd "$first_adoption"
    CONFIG_PATH="$config_path" \
      CONTRACT_REF="$ref" \
      GITHUB_OUTPUT="$output" \
      GITHUB_REPOSITORY=Verjson/example \
      GITHUB_REPOSITORY_OWNER=Verjson \
      GITHUB_RUN_ATTEMPT=1 \
      GITHUB_RUN_ID=12345 \
      JOB_WORKFLOW_SHA="$ref" \
      bash "$prepare_script"
  ) >/dev/null 2>&1; then
    echo "candidate config unexpectedly passed: $config_path" >&2
    exit 1
  fi
}

repository_marker="$tmp/repository-injection-executed"
jq --arg repository "ghcr.io/verjson/x'; touch $repository_marker; #'" \
  '.images[0].repository = $repository' \
  "$root/scripts/fixtures/container-candidate/single.json" \
  > "$first_adoption/malicious-repository.json"
run_invalid_config malicious-repository.json "$tmp/malicious-repository-output"
[ ! -e "$repository_marker" ] || {
  echo "repository configuration executed as shell source" >&2
  exit 1
}

platform_marker="$tmp/platform-injection-executed"
jq --arg os "linux'; touch $platform_marker; #'" \
  '.images[0].platforms[0].os = $os' \
  "$root/scripts/fixtures/container-candidate/single.json" \
  > "$first_adoption/malicious-platform.json"
run_invalid_config malicious-platform.json "$tmp/malicious-platform-output"
[ ! -e "$platform_marker" ] || {
  echo "platform configuration executed as shell source" >&2
  exit 1
}

jq '.images[0].platforms = [
  {"os":"linux","architecture":"amd64-v8"},
  {"os":"linux","architecture":"amd64","variant":"v8"}
]' "$root/scripts/fixtures/container-candidate/single.json" \
  > "$first_adoption/colliding-platform-fields.json"
run_invalid_config colliding-platform-fields.json "$tmp/colliding-platform-fields-output"

jq '
  .images[0].variant = "a-b"
  | .images[0].platforms = [{"os":"linux","architecture":"amd64"}]
  | .images[1].variant = "a"
  | .images[1].baseVariant = "a-b"
  | .images[1].platforms = [{"os":"b-linux","architecture":"amd64"}]
' "$root/scripts/fixtures/container-candidate/multi.json" \
  > "$first_adoption/colliding-image-platform-fields.json"
run_invalid_config colliding-image-platform-fields.json "$tmp/colliding-image-platform-fields-output"

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
grep -q 'attestations: write' "$workflow"
grep -q 'actions/attest-build-provenance@[0-9a-f]\{40\}' "$workflow"
grep -q 'actions/attest@[0-9a-f]\{40\}' "$workflow"
grep -qF '.[$platform].SPDX | select(.spdxVersion == "SPDX-2.3"' "$workflow"
grep -qF 'predicateType:"https://spdx.dev/Document/v2.3"' "$workflow"
grep -qF 'python3 "$helper" index --index "$raw_index" --reviewed-platforms "$reviewed_platforms"' "$workflow"
grep -qF 'python3 "$helper" spdx-evidence --manifest "$evidence_manifest"' "$workflow"
grep -qF 'platforms:$platforms' "$workflow"
grep -q 'commit identity already records a different digest' "$workflow"
grep -q 'imagetools create -t "\$commit_tag"' "$workflow"
if grep -Eq 'GITHUB_WORKFLOW_(REF|SHA)|github\.workflow_(ref|sha)' "$workflow"; then
  echo "called workflows cannot prove their own pin through the caller-associated github workflow identity" >&2
  exit 1
fi
if awk '/^  pull-request-build:/{seen=1} /^  publish-base:/{seen=0} seen' "$workflow" | grep -Eq 'attestations: write|packages: write|id-token: write|docker/login-action|push: true'; then
  echo "pull-request build exposes a publication capability" >&2
  exit 1
fi
attest_sbom_job="$(awk '/^  attest-sbom:/{seen=1} /^  candidate-manifest:/{seen=0} seen' "$workflow")"
attest_sbom_permissions="$(awk '
  /^    permissions:$/ { seen=1; next }
  seen && /^    [A-Za-z0-9_.-]+:/ { exit }
  seen { print }
' <<<"$attest_sbom_job")"
expected_attest_sbom_permissions="$(cat <<'PERMISSIONS'
      actions: read
      attestations: write
      contents: read
      id-token: write
      packages: write
PERMISSIONS
)"
[ "$attest_sbom_permissions" = "$expected_attest_sbom_permissions" ] || {
  echo "SBOM publication permissions are not exact least privilege" >&2
  exit 1
}
if grep -Eq 'secrets\.|NODE_AUTH_TOKEN|NPM_TOKEN|AWS_|AZURE_|GOOGLE_' <<<"$attest_sbom_job"; then
  echo "SBOM publication exposes a credential beyond its job token" >&2
  exit 1
fi
grep -qF 'uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' <<<"$attest_sbom_job" || {
  echo "SBOM evidence binding cannot read the reviewed configuration" >&2
  exit 1
}
publish_derived_job="$(awk '/^  publish-derived:/{seen=1} /^  attest-sbom:/{seen=0} seen' "$workflow")"
grep -qF 'REPOSITORY: ${{ matrix.repository }}' <<<"$publish_derived_job"
grep -qF 'IMAGE_VARIANT: ${{ matrix.variant }}' <<<"$publish_derived_job"
grep -qF 'BASE_VARIANT: ${{ matrix.baseVariant }}' <<<"$publish_derived_job"
if grep -qF -- "repository='\${{ matrix.repository }}'" <<<"$publish_derived_job" \
  || grep -qF -- "--arg variant '\${{ matrix.variant }}'" <<<"$publish_derived_job" \
  || grep -qF -- "--arg baseVariant '\${{ matrix.baseVariant }}'" <<<"$publish_derived_job"; then
  echo "publish-derived embeds candidate configuration into shell source" >&2
  exit 1
fi
grep -qF 'uses: ./.github/workflows/container-candidate.yml' "$canary"
for permission in 'actions: read' 'attestations: write' 'contents: read' 'packages: write' 'id-token: write'; do
  grep -q "^  $permission$" "$canary" || {
    echo "reusable-call canary omits $permission" >&2
    exit 1
  }
done
jq -e '.repository == "Verjson/.github" and .images[0].platforms == [{"os":"linux","architecture":"amd64"}]' \
  "$root/scripts/fixtures/container-candidate/canary.json" >/dev/null
prepare_job="$(awk '/^  prepare:/{seen=1} /^  acquire-private-node-dependencies:/{seen=0} seen' "$workflow")"
acquisition_job="$(awk '/^  acquire-private-node-dependencies:/{seen=1} /^  pull-request-build:/{seen=0} seen' "$workflow")"
grep -qF 'has-private-node-packages: ${{ steps.config.outputs.has-private-node-packages }}' <<<"$prepare_job"
grep -qF 'has-private-node-packages=$(jq -r' <<<"$prepare_job"
grep -qF 'length > 0)' <<<"$prepare_job"
grep -qF "if: needs.prepare.outputs.has-private-node-packages == 'true'" <<<"$acquisition_job"
grep -qF 'NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}' <<<"$acquisition_job"
grep -qF "# static schema predates job.workflow_sha." "$workflow"
grep -qF 'JOB_WORKFLOW_SHA: ${{ fromJSON(toJSON(job)).workflow_sha }}' "$workflow"
grep -qF '[ "$CONTRACT_REF" = "$JOB_WORKFLOW_SHA" ]' "$workflow"
grep -qF 'npm ci --ignore-scripts --no-audit --no-fund' <<<"$acquisition_job"
grep -qF 'NPM_CONFIG_USERCONFIG="$user_config"' <<<"$acquisition_job"
grep -qF 'NPM_CONFIG_GLOBALCONFIG="$global_config"' <<<"$acquisition_job"
grep -qF 'env -i \' <<<"$acquisition_job"
grep -qF 'if find . -name .npmrc -print -quit' <<<"$acquisition_job"
grep -qF 'git show "$BASE_SHA:$CONFIG_PATH"' <<<"$acquisition_job"
grep -qF '[ "$base_approved" = "$APPROVED_PRIVATE_PACKAGES" ]' <<<"$acquisition_job"

bootstrap="$tmp/bootstrap"
mkdir -p "$bootstrap"
git -C "$bootstrap" init -q
git -C "$bootstrap" config user.name fixture
git -C "$bootstrap" config user.email fixture@example.invalid
cat > "$bootstrap/container-candidate.json" <<'JSON'
{"privateNodePackages":[]}
JSON
git -C "$bootstrap" add container-candidate.json
git -C "$bootstrap" commit -qm base-config
base_sha="$(git -C "$bootstrap" rev-parse HEAD)"
cat > "$bootstrap/container-candidate.json" <<'JSON'
{"privateNodePackages":["@verjson/private-package"]}
JSON
head_approved="$(jq -ce '.privateNodePackages // []' "$bootstrap/container-candidate.json")"
base_approved="$(git -C "$bootstrap" show "$base_sha:container-candidate.json" | jq -ce '.privateNodePackages // []')"
if [ "$base_approved" = "$head_approved" ]; then
  echo "first private-package PR self-authorized credential use" >&2
  exit 1
fi
git -C "$bootstrap" add container-candidate.json
git -C "$bootstrap" commit -qm reviewed-private-config
base_sha="$(git -C "$bootstrap" rev-parse HEAD)"
base_approved="$(git -C "$bootstrap" show "$base_sha:container-candidate.json" | jq -ce '.privateNodePackages // []')"
[ "$base_approved" = "$head_approved" ] || {
  echo "reviewed base allowlist did not authorize second-stage caller adoption" >&2
  exit 1
}

grep -qF 'npm ci --ignore-scripts' <<<"$acquisition_job"
! grep -Eq 'npm (install|run|exec|rebuild)|yarn|pnpm' <<<"$acquisition_job"
! grep -Eq 'subprocess|os\.system|extract(all)?\(' "$root/scripts/container_private_dependencies.py"
grep -qF 'transfer-cache-key: ${{ steps.create-node-modules-cache-key.outputs.cache-key }}' <<<"$acquisition_job"
grep -qF 'openssl rand -hex 32' <<<"$acquisition_job"
grep -qF '[[ "$nonce" =~ ^[0-9a-f]{64}$ ]]' <<<"$acquisition_job"
grep -qF 'container-node-modules-${RUN_ID}-${RUN_ATTEMPT}-${nonce}' <<<"$acquisition_job"
grep -qF 'uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' <<<"$acquisition_job"
grep -qF 'path: .verjson-container-node-modules-${{ github.run_id }}-${{ github.run_attempt }}' <<<"$acquisition_job"
grep -qF 'key: ${{ steps.create-node-modules-cache-key.outputs.cache-key }}' <<<"$acquisition_job"
if grep -qF 'actions/upload-artifact@' <<<"$acquisition_job"; then
  echo "private dependency acquisition still uses organization artifact storage" >&2
  exit 1
fi
grep -qF 'name: Remove local acquisition and transfer state' <<<"$acquisition_job"
grep -qF 'if: always()' <<<"$acquisition_job"
for build_job in pull-request-build publish-base publish-derived; do
  build_block="$(awk -v start="  $build_job:" '
    $0 == start { seen=1; next }
    seen && /^  [A-Za-z0-9_.-]+:/ { exit }
    seen { print }
  ' "$workflow")"
  job_if="$(awk '
    /^    if:/ { seen=1; print; next }
    seen && /^      / { print; next }
    seen { exit }
  ' <<<"$build_block")"
  [ "$(grep -c '^    if:' <<<"$build_block")" -eq 1 ]
  grep -qx '    if: >-' <<<"$job_if"
  grep -qx '      always()' <<<"$job_if"
  grep -qx "      && needs.prepare.result == 'success'" <<<"$job_if"
  grep -qx "      && (needs.acquire-private-node-dependencies.result == 'success'" <<<"$job_if"
  grep -qx "      || needs.acquire-private-node-dependencies.result == 'skipped')" <<<"$job_if"
  grep -qF "build-contexts: \${{ needs.prepare.outputs.has-private-node-packages == 'true' && format('verjson_node_modules={0}/container-node-modules-context', runner.temp) || '' }}" <<<"$build_block"
  grep -qF 'uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' <<<"$build_block"
  grep -qF 'path: .verjson-container-node-modules-${{ github.run_id }}-${{ github.run_attempt }}' <<<"$build_block"
  grep -qF 'key: ${{ needs.acquire-private-node-dependencies.outputs.transfer-cache-key }}' <<<"$build_block"
  grep -qF 'fail-on-cache-miss: true' <<<"$build_block"
  grep -qF 'name: Remove local node_modules transfer state' <<<"$build_block"
  [ "$(grep -cF "needs.prepare.outputs.has-private-node-packages == 'true'" <<<"$build_block")" -ge 4 ]
  grep -qF 'run: rm -rf "$TRANSFER_DIR"' <<<"$build_block"
  if grep -qF 'restore-keys:' <<<"$build_block" || grep -qF 'actions/download-artifact@' <<<"$build_block"; then
    echo "$build_job permits an inexact cache restore or still uses artifact storage" >&2
    exit 1
  fi
  grep -qF '.verjson-lock-sha256' <<<"$build_block"
  grep -qF "NODE_AUTH_TOKEN: ''" <<<"$build_block"
  grep -qF "ACTIONS_ID_TOKEN_REQUEST_TOKEN: ''" <<<"$build_block"
  if grep -Eq 'secrets\.|secret-envs:|^[[:space:]]+secrets:' <<<"$build_block"; then
    echo "$build_job exposes a credential to PR-controlled Docker execution" >&2
    exit 1
  fi
done
if grep -Eqi 'package-lock\.json|setup-node|node_modules|npm|yarn|pnpm|BASE_SHA|git (show|cat-file|ls-tree)' <<<"$prepare_job"; then
  echo "credential-free preparation imposes Node or reviewed-base requirements" >&2
  exit 1
fi
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
