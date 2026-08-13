#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

awk '$0=="      - name: Prepare failed DeepSeek pass 1 replay"{f=1;next} f&&$0=="        run: |"{r=1;next} r{if($0~/^      - name:/)exit;sub(/^          /,"");print}' \
  "$workflow" >"$tmp/handoff.sh"
[ -s "$tmp/handoff.sh" ]

cat >"$tmp/prepare-deepseek-replay.py" <<'PY'
import json
import os
import sys
from pathlib import Path

Path(os.environ["CAPTURE"]).write_text(json.dumps(sys.argv[1:]), encoding="utf-8")
with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
    output.write("available=false\n")
PY

export RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$tmp/output" CAPTURE="$tmp/args.json"
export TRANSPORT=success USABLE=false PUBLICATION=success
export EXPECTED_MODEL=deepseek-v4-pro EXPECTED_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export EXPECTED_SENSITIVE=false EXPECTED_TRUSTED_REVIEW_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export AUTHORIZATION_CHECK_ID=9001 TARGET_REPO=Verjson/example PR_NUMBER=7

diagnostic_json='{"path":"findings[0].evidence","expected":"exact fragment","observed":"fragment mismatch"}'
DIAGNOSTIC="$diagnostic_json" bash "$tmp/handoff.sh"
python3 - "$tmp/args.json" "$diagnostic_json" <<'PY'
import json
import sys

args = json.load(open(sys.argv[1], encoding="utf-8"))
index = args.index("--diagnostic")
assert args[index + 1] == sys.argv[2]
assert json.loads(args[index + 1])["observed"] == "fragment mismatch"
PY

DIAGNOSTIC='' bash "$tmp/handoff.sh"
python3 - "$tmp/args.json" <<'PY'
import json
import sys

args = json.load(open(sys.argv[1], encoding="utf-8"))
assert args[args.index("--diagnostic") + 1] == "{}"
PY

echo "DeepSeek replay shell handoff: ok"
