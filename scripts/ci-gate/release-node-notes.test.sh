#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
workflow="$repo_root/.github/workflows/node-release.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '
  /RESTART_SAFE_GH_RELEASE_BEGIN/ { active = 1 }
  active { sub(/^          /, ""); print }
  /RESTART_SAFE_GH_RELEASE_END/ { exit }
' "$workflow" >"$work/release-notes.sh"
bash -n "$work/release-notes.sh"

mkdir -p "$work/bin" "$work/repo/CHANGELOG" "$work/state"
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = release ]
case "$2" in
  view)
    [ -e "$TEST_STATE/release" ] || exit 1
    printf '%s\n' "$VERSION"
    ;;
  create|edit)
    action="$2"
    shift 2
    notes=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --notes-file ]; then
        notes="$2"
        break
      fi
      shift
    done
    [ -n "$notes" ] && [ -f "$notes" ]
    cp "$notes" "$TEST_STATE/$action-notes"
    touch "$TEST_STATE/release"
    ;;
  *) exit 90 ;;
esac
STUB
chmod +x "$work/bin/gh"

run_notes() {
  (
    cd "$work/repo"
    env -u RUNNER_TEMP \
      PATH="$work/bin:$PATH" \
      TEST_STATE="$work/state" \
      VERSION=v1.2.3 \
      GH_TOKEN=test \
      GITHUB_SERVER_URL=https://github.example \
      GITHUB_REPOSITORY=acme/widgets \
      bash -euo pipefail "$work/release-notes.sh"
  )
}

snapshot="$work/repo/CHANGELOG/v1.2.3.md"

printf '%s\n' 'exact short notes' >"$snapshot"
run_notes
cmp -s "$snapshot" "$work/state/create-notes"
echo "ok - an under-limit snapshot is passed through byte-for-byte"

rm -rf "$work/state"; mkdir -p "$work/state"
head -c 124999 /dev/zero | tr '\0' a >"$snapshot"
printf '\n' >>"$snapshot"
[ "$(wc -c <"$snapshot")" -eq 125000 ]
run_notes
cmp -s "$snapshot" "$work/state/create-notes"
echo "ok - a snapshot exactly at the byte boundary is not truncated"

rm -rf "$work/state"; mkdir -p "$work/state"
node - "$snapshot" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
const prefix = "kept line\n" + "a".repeat(119989);
fs.writeFileSync(path, prefix + "😀\n" + "discarded\n" + "z".repeat(6000));
NODE
[ "$(wc -c <"$snapshot")" -gt 125000 ]
run_notes
notes="$work/state/create-notes"
[ "$(wc -c <"$notes")" -le 125000 ]
node - "$notes" <<'NODE'
const fs = require("fs");
const notes = new TextDecoder("utf-8", { fatal: true }).decode(fs.readFileSync(process.argv[2]));
const link = "[`CHANGELOG/v1.2.3.md`](https://github.example/acme/widgets/blob/v1.2.3/CHANGELOG/v1.2.3.md)._\n";
if (!notes.endsWith(link)) throw new Error("bounded notes do not end with the immutable snapshot link");
NODE
grep -q '^kept line$' "$notes"
if grep -q 'discarded' "$notes"; then
  echo "FAIL - bounded notes retained content beyond the byte budget" >&2
  exit 1
fi
echo "ok - an oversized multibyte snapshot truncates on a valid line boundary and links the immutable full snapshot"

run_notes
cmp -s "$work/state/create-notes" "$work/state/edit-notes"
echo "ok - a missing RUNNER_TEMP falls back safely and create/edit reruns publish identical bounded notes"
