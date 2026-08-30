#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / ".github/workflows/node-ci.yml"
TARGET = ROOT / ".github/workflows/node-ci-protected.yml"

CREDENTIAL_ENV_KEYS = (
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "NODE_AUTH_TOKEN",
    "NPM_TOKEN",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "AZURE_CREDENTIALS",
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
    "ACTIONS_ID_TOKEN_REQUEST_URL",
)

CANDIDATE_CACHE_MAX_FILES = 4096
CANDIDATE_CACHE_MAX_BYTES = 268435456

INPUTS = """      event-name:\n        description: Authenticated pull-request event identity.\n        required: true\n        type: string\n+      head-repository:\n        description: Authenticated pull-request head repository.\n        required: true\n        type: string\n+      head-sha:\n        description: Authenticated immutable pull-request head SHA.\n        required: true\n        type: string\n+"""

VERIFY_STEP = """      - name: Revalidate protected pull-request identity\n        env:\n          ADMITTED_EVENT: ${{ inputs.event-name }}\n          ADMITTED_HEAD_REPOSITORY: ${{ inputs.head-repository }}\n          ADMITTED_HEAD_SHA: ${{ inputs.head-sha }}\n          GH_TOKEN: ${{ github.token }}\n          REPOSITORY: ${{ github.repository }}\n          RUN_ID: ${{ github.run_id }}\n        run: |\n          set -euo pipefail\n          [ "$ADMITTED_EVENT" = pull_request ]\n          [ -n "$ADMITTED_HEAD_REPOSITORY" ]\n          [[ "$ADMITTED_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]\n          [[ "$RUN_ID" =~ ^[1-9][0-9]*$ ]]\n          run_record="$(gh api "repos/$REPOSITORY/actions/runs/$RUN_ID" --jq '[.event,.head_sha,(.pull_requests|length),(.pull_requests[0].number//"")]|@tsv')"\n          IFS=$'\\t' read -r run_event run_head binding_count pr_number <<<"$run_record"\n          [ "$run_event" = "$ADMITTED_EVENT" ]\n          [ "$run_head" = "$ADMITTED_HEAD_SHA" ]\n          [ "$binding_count" = 1 ]\n          [[ "$pr_number" =~ ^[1-9][0-9]*$ ]]\n          pr_record="$(gh api "repos/$REPOSITORY/pulls/$pr_number" --jq '[.state,.head.repo.full_name,.head.sha]|@tsv')"\n          IFS=$'\\t' read -r pr_state pr_head_repository pr_head_sha <<<"$pr_record"\n          [ "$pr_state" = open ]\n          [ "$pr_head_repository" = "$ADMITTED_HEAD_REPOSITORY" ]\n          [ "$pr_head_sha" = "$ADMITTED_HEAD_SHA" ]\n+"""


INPUTS = INPUTS.replace("\n+", "\n")
VERIFY_STEP = VERIFY_STEP.replace("\n+", "\n")


def verifier_step(condition: str | None = None) -> str:
    if condition is None:
        return VERIFY_STEP
    marker = "        env:\n"
    if VERIFY_STEP.count(marker) != 1:
        raise SystemExit("protected verifier env marker drifted")
    return VERIFY_STEP.replace(marker, f"        if: {condition}\n{marker}")


def replace_once(document: str, old: str, new: str) -> str:
    if document.count(old) != 1:
        raise SystemExit(
            f"protected node-ci generator expected one {old.splitlines()[0]!r} boundary, "
            f"found {document.count(old)}"
        )
    return document.replace(old, new)


def remove_candidate_credentials(document: str, step_name: str) -> str:
    step_marker = f"      - name: {step_name}\n"
    if document.count(step_marker) != 1:
        raise SystemExit(
            f"protected node-ci expected one candidate step {step_name!r}, "
            f"found {document.count(step_marker)}"
        )
    step_start = document.index(step_marker)
    step_end = document.find("\n      - ", step_start + len(step_marker))
    if step_end == -1:
        step_end = len(document)
    step = document[step_start:step_end]
    run_marker = "        run: |\n"
    if step.count(run_marker) != 1:
        raise SystemExit(f"protected candidate step {step_name!r} has no unique run block")
    unset = "          unset -v " + " ".join(CREDENTIAL_ENV_KEYS) + "\n"
    protected_step = step.replace(run_marker, run_marker + unset, 1)
    return document[:step_start] + protected_step + document[step_end:]


def isolate_candidate_runtime_cache(document: str) -> str:
    step_name = "Run exact credentialless consumer script plan"
    plan_if = (
        "needs.eligibility.outputs.should-run != 'false' && "
        "(inputs.secretless-pr || inputs.secretless-trusted-ref) && "
        "inputs.secretless-ci-script-plan != ''"
    )
    step_marker = f"      - name: {step_name}\n"
    step_start = document.index(step_marker)
    step_end = document.find("\n      - ", step_start + len(step_marker))
    if step_end == -1:
        raise SystemExit(f"protected candidate step {step_name!r} must not be last")
    step = document[step_start:step_end]
    plan_env_lines = [
        line
        for line in step.splitlines(keepends=True)
        if line.startswith("          CI_SCRIPT_PLAN:")
    ]
    if len(plan_env_lines) != 1:
        raise SystemExit(
            f"protected candidate script plan environment changed: {len(plan_env_lines)}"
        )
    plan_env = plan_env_lines[0]
    isolated_plan_env = plan_env + (
        "          CANDIDATE_CACHE_ROOT: "
        "${{ runner.temp }}/verjson-candidate-caches-${{ github.run_id }}-"
        "${{ github.run_attempt }}-${{ github.job }}\n"
    )
    step = step.replace(plan_env, isolated_plan_env, 1)
    imports = """          import json
          import os
          import re
          import subprocess
          import sys
          from pathlib import Path
"""
    protected_imports = """          import hashlib
          import json
          import os
          import re
          import shutil
          import signal
          import stat
          import subprocess
          import sys
          import time
          from pathlib import Path
"""
    if step.count(imports) != 1:
        raise SystemExit("protected candidate script plan imports changed")
    step = step.replace(imports, protected_imports, 1)
    execution = """          for name, unset_env in normalized:
              script_env = os.environ.copy()
              for env_name in unset_env:
                  script_env.pop(env_name, None)
              subprocess.run(["npm", "run", name], check=True, env=script_env)
"""
    isolated_execution = f"""          max_cache_files = {CANDIDATE_CACHE_MAX_FILES}
          max_cache_bytes = {CANDIDATE_CACHE_MAX_BYTES}
          runner_temp_input = Path(os.environ["RUNNER_TEMP"])
          if (
              not runner_temp_input.is_absolute()
              or runner_temp_input.is_symlink()
              or not runner_temp_input.is_dir()
              or runner_temp_input.resolve() != runner_temp_input
          ):
              sys.exit("RUNNER_TEMP is not a canonical directory")
          runner_temp = runner_temp_input
          baseline = Path(os.path.abspath(os.environ["npm_config_cache"]))
          if not baseline.is_absolute() or baseline.is_symlink() or not baseline.is_dir():
              sys.exit("verified runtime cache is not an absolute regular directory")
          if baseline.resolve() != baseline:
              sys.exit("verified runtime cache path contains a symlink")
          try:
              baseline.resolve().relative_to(runner_temp)
          except ValueError:
              sys.exit("verified runtime cache escapes RUNNER_TEMP")

          bubblewrap = Path("/usr/bin/bwrap")
          try:
              bubblewrap_metadata = bubblewrap.stat(follow_symlinks=False)
          except OSError:
              sys.exit("verified bubblewrap namespace boundary is unavailable")
          if (
              not stat.S_ISREG(bubblewrap_metadata.st_mode)
              or bubblewrap_metadata.st_uid != 0
              or bubblewrap_metadata.st_mode & 0o022
          ):
              sys.exit("bubblewrap namespace boundary has unsafe ownership or mode")
          bubblewrap_version = subprocess.run(
              [str(bubblewrap), "--version"],
              check=True,
              capture_output=True,
              text=True,
          ).stdout
          version_match = re.fullmatch(r"bubblewrap (\\d+)\\.(\\d+)\\.(\\d+)\\n?", bubblewrap_version)
          if version_match is None or tuple(map(int, version_match.groups())) < (0, 9, 0):
              sys.exit("bubblewrap namespace boundary is below version 0.9.0")

          def inventory(root):
              files = []
              total_bytes = 0
              pending = [root]
              while pending:
                  directory = pending.pop()
                  for entry in os.scandir(directory):
                      entry_path = Path(entry.path)
                      mode = entry.stat(follow_symlinks=False).st_mode
                      if stat.S_ISLNK(mode):
                          sys.exit("verified runtime cache contains a symlink")
                      if stat.S_ISDIR(mode):
                          pending.append(entry_path)
                          continue
                      if not stat.S_ISREG(mode):
                          sys.exit("verified runtime cache contains a special file")
                      try:
                          relative = entry_path.relative_to(root).as_posix()
                      except ValueError:
                          sys.exit("verified runtime cache entry escapes its root")
                      try:
                          descriptor = os.open(entry_path, os.O_RDONLY | os.O_NOFOLLOW)
                      except OSError:
                          sys.exit("verified runtime cache file changed during validation")
                      descriptor_stat = os.fstat(descriptor)
                      if not stat.S_ISREG(descriptor_stat.st_mode):
                          os.close(descriptor)
                          sys.exit("verified runtime cache file changed type during validation")
                      size = descriptor_stat.st_size
                      total_bytes += size
                      if len(files) + 1 > max_cache_files or total_bytes > max_cache_bytes:
                          sys.exit("verified runtime cache exceeds its file or byte bound")
                      digest = hashlib.sha256()
                      with os.fdopen(descriptor, "rb") as stream:
                          for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                              digest.update(chunk)
                      files.append((relative, size, digest.hexdigest()))
              return tuple(sorted(files))

          baseline_inventory = inventory(baseline)
          cache_root = Path(os.environ["CANDIDATE_CACHE_ROOT"])
          if (
              not cache_root.is_absolute()
              or Path(os.path.abspath(cache_root)) != cache_root
              or cache_root.parent.resolve() != runner_temp
          ):
              sys.exit("candidate cache root escapes RUNNER_TEMP")
          if cache_root.exists() or cache_root.is_symlink():
              sys.exit("candidate cache root exists before script execution")
          workspace_lexical = Path(os.environ.get("PWD", ""))
          workspace = Path.cwd().resolve()
          if (
            not workspace_lexical.is_absolute()
            or workspace_lexical != workspace
            or workspace_lexical.resolve() != workspace_lexical
            or workspace_lexical.is_symlink()
            or not workspace.is_dir()
          ):
            sys.exit("candidate workspace is not a canonical directory")
          if workspace == runner_temp or workspace in runner_temp.parents or runner_temp in workspace.parents:
              sys.exit("candidate workspace and RUNNER_TEMP overlap")
          if baseline.parent != runner_temp or cache_root.parent != runner_temp:
              sys.exit("candidate cache roots are not exact RUNNER_TEMP children")
          if baseline == cache_root or baseline in cache_root.parents or cache_root in baseline.parents:
              sys.exit("candidate cache baseline and isolation root overlap")
          if any(os.environ.get(name) for name in ("DB_HOST", "DB_PORT", "CACHE_PORT")):
              sys.exit("protected candidate scripts do not permit shared service networking")

          trusted_tool_root_input = Path(os.environ.get("RUNNER_TOOL_CACHE", ""))
          if (
              not trusted_tool_root_input.is_absolute()
              or trusted_tool_root_input.is_symlink()
              or not trusted_tool_root_input.is_dir()
              or trusted_tool_root_input.resolve() != trusted_tool_root_input
          ):
              sys.exit("trusted setup-node tool root unavailable or noncanonical")
          trusted_tool_root = trusted_tool_root_input

          def paths_overlap(left, right):
            return left == right or left in right.parents or right in left.parents

          def validate_trusted_ancestry(root, target, allowed_uids, label, include_target=True):
            try:
              relative = target.relative_to(root)
            except ValueError:
              sys.exit(f"{{label}} escapes its trusted root")
            components = (root,)
            current = root
            for part in relative.parts:
              current = current / part
              components += (current,)
            if not include_target:
              components = components[:-1]
            for component in components:
              try:
                metadata = component.stat(follow_symlinks=False)
              except OSError:
                sys.exit(f"{{label}} ancestry is unreadable")
              if component != target or not include_target:
                if not stat.S_ISDIR(metadata.st_mode):
                  sys.exit(f"{{label}} ancestry is not canonical directories")
              if metadata.st_uid not in allowed_uids or metadata.st_mode & 0o022:
                sys.exit(f"{{label}} ancestry has unsafe ownership mode")

          candidate_controlled_roots = (workspace, runner_temp, baseline, cache_root)
          if any(paths_overlap(trusted_tool_root, path) for path in candidate_controlled_roots):
              sys.exit("trusted setup-node tool root overlaps candidate-controlled paths")
          trusted_root_metadata = trusted_tool_root.stat(follow_symlinks=False)
          if (
            not stat.S_ISDIR(trusted_root_metadata.st_mode)
            or trusted_root_metadata.st_uid != 0
            or trusted_root_metadata.st_mode & 0o022
          ):
            sys.exit("trusted setup-node tool root has unsafe ownership mode")
          trusted_tool_uids = (0,)

          trusted_search_directories = []
          for entry in os.environ.get("PATH", "").split(os.pathsep):
            if not entry:
              continue
            lexical_directory = Path(entry)
            if not lexical_directory.is_absolute():
              continue
            try:
              lexical_directory.relative_to(trusted_tool_root)
            except ValueError:
              continue
            resolved_directory = lexical_directory.resolve()
            try:
              resolved_directory.relative_to(trusted_tool_root)
            except ValueError:
              sys.exit("setup-node PATH entry escapes trusted tool root")
            validate_trusted_ancestry(
              trusted_tool_root,
              lexical_directory,
              trusted_tool_uids,
              "setup-node lexical PATH",
            )
            validate_trusted_ancestry(
              trusted_tool_root,
              resolved_directory,
              trusted_tool_uids,
              "setup-node resolved PATH",
            )
            if resolved_directory not in trusted_search_directories:
              trusted_search_directories.append(resolved_directory)

          tool_executables = {{}}
          for tool_name in ("npm", "node", "pwsh"):
            candidates = []
            if tool_name == "pwsh":
              system_candidate = Path("/usr/bin/pwsh")
              if system_candidate.exists():
                resolved_system_candidate = system_candidate.resolve()
                microsoft_root = Path("/opt/microsoft/powershell")
                if (
                  not resolved_system_candidate.is_relative_to(microsoft_root)
                  or resolved_system_candidate.name != "pwsh"
                  or not re.fullmatch(r"[0-9]+(?:[.][0-9]+)*", resolved_system_candidate.parent.name)
                ):
                  sys.exit("trusted pwsh executable escapes Microsoft runtime contract")
                validate_trusted_ancestry(
                  Path("/usr"), system_candidate, (0,), "pwsh lexical path", include_target=False
                )
                validate_trusted_ancestry(
                  Path("/opt"), resolved_system_candidate.parent, (0,), "pwsh resolved runtime"
                )
                system_metadata = resolved_system_candidate.stat(follow_symlinks=False)
                if system_metadata.st_uid != 0 or system_metadata.st_mode & 0o022:
                  sys.exit("trusted pwsh executable has unsafe ownership mode")
                candidates.append(resolved_system_candidate)
            for directory in trusted_search_directories:
              lexical_candidate = directory / tool_name
              if not lexical_candidate.exists():
                continue
              resolved_candidate = lexical_candidate.resolve()
              validate_trusted_ancestry(
                trusted_tool_root,
                lexical_candidate,
                trusted_tool_uids,
                f"trusted {{tool_name}} lexical path",
                include_target=False,
              )
              try:
                resolved_candidate.relative_to(trusted_tool_root)
              except ValueError:
                sys.exit(f"trusted {{tool_name}} executable escapes setup-node tool root")
              validate_trusted_ancestry(
                trusted_tool_root,
                resolved_candidate,
                trusted_tool_uids,
                f"trusted {{tool_name}} resolved path",
              )
              if resolved_candidate.is_file() and os.access(resolved_candidate, os.X_OK):
                candidates.append(resolved_candidate)
            candidates = list(dict.fromkeys(candidates))
            if not candidates:
              if tool_name in ("npm", "node"):
                sys.exit(f"trusted {{tool_name}} executable is unavailable")
              continue
            if len(candidates) != 1:
              sys.exit(f"trusted {{tool_name}} executable is ambiguous")
            tool_executable = candidates[0]
            executable_metadata = tool_executable.stat(follow_symlinks=False)
            if executable_metadata.st_uid != 0 or executable_metadata.st_mode & 0o022:
              sys.exit(f"trusted {{tool_name}} executable has unsafe ownership mode")
            tool_executables[tool_name] = tool_executable
          npm_executable = tool_executables["npm"]
          tool_prefix_candidates = {{
            (executable.parent if executable.is_relative_to("/opt/microsoft/powershell") else executable.parent.parent)
            for executable in tool_executables.values()
            if not executable.is_relative_to("/usr")
          }}
          tool_prefixes = []
          tool_prefix_identities = {{}}

          def validate_root_owned_tool_tree(root):
            for directory, directory_names, file_names in os.walk(root, followlinks=False):
              directory_path = Path(directory)
              directory_metadata = directory_path.stat(follow_symlinks=False)
              if (
                not stat.S_ISDIR(directory_metadata.st_mode)
                or directory_metadata.st_uid != 0
                or directory_metadata.st_mode & 0o022
              ):
                sys.exit("trusted tool tree directory has unsafe ownership mode")
              for name in (*directory_names, *file_names):
                entry = directory_path / name
                entry_metadata = entry.stat(follow_symlinks=False)
                if entry_metadata.st_uid != 0:
                  sys.exit("trusted tool tree entry is not root owned")
                if stat.S_ISLNK(entry_metadata.st_mode):
                  resolved_entry = entry.resolve()
                  if not resolved_entry.is_relative_to(root):
                    sys.exit("trusted tool tree symlink escapes mounted prefix")
                  continue
                if entry_metadata.st_mode & 0o022:
                  sys.exit("trusted tool tree entry has unsafe writable mode")
                if not (stat.S_ISDIR(entry_metadata.st_mode) or stat.S_ISREG(entry_metadata.st_mode)):
                  sys.exit("trusted tool tree contains special file")

          for tool_prefix in sorted(tool_prefix_candidates, key=lambda path: (len(path.parts), str(path))):
            if (
                tool_prefix == Path("/")
                or any(paths_overlap(tool_prefix, path) for path in candidate_controlled_roots)
            ):
              sys.exit("trusted tool prefix overlaps candidate-controlled paths")
            if tool_prefix.is_relative_to(trusted_tool_root):
              validate_trusted_ancestry(
                trusted_tool_root, tool_prefix, trusted_tool_uids, "trusted tool prefix"
              )
            prefix_metadata = tool_prefix.stat(follow_symlinks=False)
            if not stat.S_ISDIR(prefix_metadata.st_mode):
              sys.exit("trusted tool prefix is not a directory")
            validate_root_owned_tool_tree(tool_prefix)
            tool_prefix_identities[tool_prefix] = (
              prefix_metadata.st_dev,
              prefix_metadata.st_ino,
              prefix_metadata.st_uid,
              stat.S_IMODE(prefix_metadata.st_mode),
            )
            if not any(existing == tool_prefix or existing in tool_prefix.parents for existing in tool_prefixes):
              tool_prefixes.append(tool_prefix)
          cache_root.mkdir(mode=0o700)
          active_process = None
          received_signal = None

          def cleanup_cache_root(*_args):
              global active_process
              if active_process is not None and active_process.poll() is None:
                  try:
                      os.killpg(active_process.pid, signal.SIGTERM)
                  except ProcessLookupError:
                      pass
              shutil.rmtree(cache_root, ignore_errors=True)

          def extinguish_process_group(process):
              graceful_deadline = time.monotonic() + 1
              while time.monotonic() < graceful_deadline:
                  try:
                      os.killpg(process.pid, 0)
                  except ProcessLookupError:
                      return
                  time.sleep(0.05)
              try:
                  os.killpg(process.pid, signal.SIGKILL)
              except ProcessLookupError:
                  return
              deadline = time.monotonic() + 5
              while True:
                  try:
                      os.killpg(process.pid, 0)
                  except ProcessLookupError:
                      return
                  if time.monotonic() >= deadline:
                      sys.exit("candidate process group survived bounded SIGKILL cleanup")
                  time.sleep(0.05)

          previous_handlers = {{}}
          def handle_signal(signum, _frame):
              global received_signal
              signal.signal(signal.SIGINT, signal.SIG_IGN)
              signal.signal(signal.SIGTERM, signal.SIG_IGN)
              received_signal = signum
              if active_process is not None and active_process.poll() is None:
                  try:
                      os.killpg(active_process.pid, signal.SIGTERM)
                  except ProcessLookupError:
                      pass

          for caught_signal in (signal.SIGINT, signal.SIGTERM):
              previous_handlers[caught_signal] = signal.getsignal(caught_signal)
              signal.signal(caught_signal, handle_signal)
          try:
              for index, (name, unset_env) in enumerate(normalized):
                  if inventory(baseline) != baseline_inventory:
                      sys.exit("verified runtime cache changed before candidate script")
                  script_cache = cache_root / str(index)
                  script_cache.mkdir(mode=0o700)
                  script_tmp = cache_root / f"tmp-{{index}}"
                  script_home = cache_root / f"home-{{index}}"
                  script_tmp.mkdir(mode=0o700)
                  script_home.mkdir(mode=0o700)
                  for relative, _size, _digest in baseline_inventory:
                      source = baseline / relative
                      target = script_cache / relative
                      target.parent.mkdir(parents=True, exist_ok=True)
                      try:
                          source_descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
                      except OSError:
                          sys.exit("verified runtime cache changed during isolated copy")
                      if not stat.S_ISREG(os.fstat(source_descriptor).st_mode):
                          os.close(source_descriptor)
                          sys.exit("verified runtime cache copy source is not a regular file")
                      with (
                          os.fdopen(source_descriptor, "rb") as source_stream,
                          target.open("xb") as target_stream,
                      ):
                          shutil.copyfileobj(source_stream, target_stream, length=1024 * 1024)
                  if inventory(baseline) != baseline_inventory or inventory(script_cache) != baseline_inventory:
                      sys.exit("isolated candidate cache copy failed integrity verification")
                  script_env = os.environ.copy()
                  for env_name in unset_env:
                      script_env.pop(env_name, None)
                  script_env["NPM_CONFIG_CACHE"] = str(script_cache)
                  script_env["npm_config_cache"] = str(script_cache)
                  script_env["HOME"] = str(script_home)
                  script_env["TMPDIR"] = str(script_tmp)
                  tool_path_entries = [
                      *(str(executable.parent) for executable in tool_executables.values()),
                      "/usr/local/bin",
                      "/usr/bin",
                      "/bin",
                  ]
                  script_env["PATH"] = ":".join(dict.fromkeys(tool_path_entries))
                  isolated_paths = (script_cache, script_tmp, script_home)
                  if len(set(isolated_paths)) != len(isolated_paths):
                      sys.exit("candidate writable mount paths are not distinct")
                  if any(
                      left == right or left in right.parents or right in left.parents
                      for position, left in enumerate(isolated_paths)
                      for right in isolated_paths[position + 1:]
                  ):
                      sys.exit("candidate writable mount paths overlap")
                  mount_targets = (workspace, cache_root, *isolated_paths, *tool_prefixes)
                  namespace_directories = set()
                  for target in mount_targets:
                      namespace_directories.add(target)
                      namespace_directories.update(target.parents)
                  namespace_directories.discard(Path("/"))
                  directory_args = []
                  for directory in sorted(namespace_directories, key=lambda path: (len(path.parts), str(path))):
                      if directory == Path("/usr") or directory.is_relative_to("/usr"):
                          continue
                      directory_args.extend(("--dir", str(directory)))
                  protected_parents = {{workspace.parent, runner_temp, cache_root}}
                  chmod_args = []
                  for directory in sorted(protected_parents, key=str):
                      chmod_args.extend(("--chmod", "0555", str(directory)))
              tool_mount_args = []
              tool_prefix_fds = []
              try:
                for tool_prefix in tool_prefixes:
                  descriptor = os.open(
                    tool_prefix,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
                  )
                  descriptor_metadata = os.fstat(descriptor)
                  descriptor_identity = (
                    descriptor_metadata.st_dev,
                    descriptor_metadata.st_ino,
                    descriptor_metadata.st_uid,
                    stat.S_IMODE(descriptor_metadata.st_mode),
                  )
                  if descriptor_identity != tool_prefix_identities[tool_prefix]:
                    os.close(descriptor)
                    sys.exit("trusted tool prefix changed before namespace bind")
                  tool_prefix_fds.append(descriptor)
                  tool_mount_args.extend(
                    ("--ro-bind", f"/proc/self/fd/{{descriptor}}", str(tool_prefix))
                  )
              except BaseException:
                for descriptor in tool_prefix_fds:
                  os.close(descriptor)
                raise
              try:
                active_process = subprocess.Popen(
                          [
                              str(bubblewrap),
                              "--unshare-user",
                              "--unshare-pid",
                              "--unshare-ipc",
                              "--unshare-uts",
                              "--unshare-cgroup-try",
                              "--unshare-net",
                              "--disable-userns",
                              "--die-with-parent",
                              "--new-session",
                              "--cap-drop", "ALL",
                              "--tmpfs", "/",
                              "--tmpfs", "/tmp",
                              *directory_args,
                              *chmod_args,
                              "--ro-bind", "/usr", "/usr",
                              "--ro-bind", "/bin", "/bin",
                              "--ro-bind", "/lib", "/lib",
                              "--ro-bind", "/lib64", "/lib64",
                              "--ro-bind", "/etc/ssl", "/etc/ssl",
                              "--ro-bind", "/etc/hosts", "/etc/hosts",
                              "--ro-bind", "/etc/resolv.conf", "/etc/resolv.conf",
                              "--ro-bind", "/etc/nsswitch.conf", "/etc/nsswitch.conf",
                              "--ro-bind", "/etc/passwd", "/etc/passwd",
                              "--ro-bind", "/etc/group", "/etc/group",
                              *tool_mount_args,
                              "--bind", str(workspace), str(workspace),
                              "--bind", str(script_cache), str(script_cache),
                              "--bind", str(script_home), str(script_home),
                              "--bind", str(script_tmp), str(script_tmp),
                              "--proc", "/proc",
                              "--dev", "/dev",
                              "--chdir", str(workspace),
                              "--",
                              str(npm_executable), "run", name,
                          ],
                          env=script_env,
                          start_new_session=True,
                          pass_fds=tuple(tool_prefix_fds),
                        )
                for descriptor in tool_prefix_fds:
                  os.close(descriptor)
                tool_prefix_fds = []
                while active_process.poll() is None:
                  time.sleep(0.05)
                candidate_status = active_process.returncode
                extinguish_process_group(active_process)
                if received_signal is not None:
                  raise SystemExit(128 + received_signal)
                if candidate_status != 0:
                  raise subprocess.CalledProcessError(candidate_status, active_process.args)
              finally:
                for descriptor in tool_prefix_fds:
                  os.close(descriptor)
                if active_process is not None:
                  extinguish_process_group(active_process)
                active_process = None
                shutil.rmtree(script_cache, ignore_errors=True)
                shutil.rmtree(script_tmp, ignore_errors=True)
                shutil.rmtree(script_home, ignore_errors=True)
                if (
                  script_cache.exists()
                  or script_tmp.exists()
                  or script_home.exists()
                  or inventory(baseline) != baseline_inventory
                ):
                  sys.exit("candidate script cache cleanup or baseline integrity check failed")
          finally:
              cleanup_cache_root()
              for caught_signal, previous_handler in previous_handlers.items():
                  signal.signal(caught_signal, previous_handler)
          if cache_root.exists() or inventory(baseline) != baseline_inventory:
              sys.exit("candidate cache root cleanup or final baseline integrity check failed")
"""
    if step.count(execution) != 1:
        raise SystemExit("protected candidate script execution block changed")
    step = step.replace(execution, isolated_execution, 1)
    python_start = "          python3 - <<'PY'\n"
    python_end = "          PY"
    if step.count(python_start) != 1 or step.count(python_end) != 1:
        raise SystemExit("protected candidate script Python boundary changed")
    supervised_start = """          candidate_cache_supervisor_pid=''
          forward_candidate_signal() {
            signal="$1"
            trap - INT TERM
            [ -z "$candidate_cache_supervisor_pid" ] || kill -s "$signal" "$candidate_cache_supervisor_pid" 2>/dev/null || true
            [ -z "$candidate_cache_supervisor_pid" ] || wait "$candidate_cache_supervisor_pid" 2>/dev/null || true
            exit "$2"
          }
          trap 'forward_candidate_signal INT 130' INT
          trap 'forward_candidate_signal TERM 143' TERM
          python3 - <<'PY' &
"""
    supervised_end = '''          PY
          candidate_cache_supervisor_pid=$!
          candidate_cache_status=0
          wait "$candidate_cache_supervisor_pid" || candidate_cache_status=$?
          trap - INT TERM
          exit "$candidate_cache_status"
'''
    step = step.replace(python_start, supervised_start, 1)
    step = step.replace(python_end, supervised_end, 1)
    cleanup_step = f"""
      - name: Remove isolated candidate runtime caches
        if: always() && {plan_if}
        env:
          CANDIDATE_CACHE_ROOT: ${{{{ runner.temp }}}}/verjson-candidate-caches-${{{{ github.run_id }}}}-${{{{ github.run_attempt }}}}-${{{{ github.job }}}}
        run: |
          set -euo pipefail
          expected="$RUNNER_TEMP/verjson-candidate-caches-${{{{ github.run_id }}}}-${{{{ github.run_attempt }}}}-${{{{ github.job }}}}"
          [ "$CANDIDATE_CACHE_ROOT" = "$expected" ]
          case "$CANDIDATE_CACHE_ROOT" in
            "$RUNNER_TEMP"/verjson-candidate-caches-*) ;;
            *) exit 1 ;;
          esac
          rm -rf -- "$CANDIDATE_CACHE_ROOT"
          [ ! -e "$CANDIDATE_CACHE_ROOT" ] && [ ! -L "$CANDIDATE_CACHE_ROOT" ]
"""
    return document[:step_start] + step + cleanup_step + document[step_end:]


def remove_step(document: str, step_name: str) -> str:
    step_marker = f"      - name: {step_name}\n"
    if document.count(step_marker) != 1:
        raise SystemExit(
            f"protected node-ci expected one unsupported step {step_name!r}, "
            f"found {document.count(step_marker)}"
        )
    step_start = document.index(step_marker)
    step_end = document.find("\n      - ", step_start + len(step_marker))
    if step_end == -1:
        raise SystemExit(f"protected unsupported step {step_name!r} must not be last")
    return document[:step_start] + document[step_end + 1:]


def render() -> str:
    document = SOURCE.read_text(encoding="utf-8")
    document = replace_once(document, "# Reusable CI for the verJSON Node libraries:", "# Generated by scripts/gen-node-ci-protected.py; do not edit.\n# Protected required-workflow Node.js CI variant:")
    document = replace_once(document, "      db-image:\n", INPUTS + "      db-image:\n")
    document = replace_once(document, "          HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}", "          HEAD_SHA: ${{ inputs.head-sha }}")
    document = replace_once(document, "    permissions:\n      contents: read\n      packages: read\n", "    permissions:\n      actions: read\n      contents: read\n      packages: read\n      pull-requests: read\n")
    document = replace_once(document, "          EVENT_NAME: ${{ github.event_name }}\n          HEAD_REPOSITORY: ${{ github.event.pull_request.head.repo.full_name }}", "          EVENT_NAME: ${{ inputs.event-name }}\n          HEAD_REPOSITORY: ${{ inputs.head-repository }}")
    document = replace_once(document, "    if: (inputs.secretless-pr || inputs.secretless-trusted-ref) && needs.eligibility.outputs.should-run != 'false'\n", "    if: needs.eligibility.outputs.should-run != 'false'\n")
    document = replace_once(document, "          [ \"$SECRETLESS_PR\" != \"$SECRETLESS_TRUSTED_REF\" ] || {\n", "          [ \"$SECRETLESS_PR\" = true ] && [ \"$SECRETLESS_TRUSTED_REF\" = false ] || {\n            echo \"::error::protected node-ci requires secretless-pr=true and secretless-trusted-ref=false\"\n            exit 1\n          }\n          [ \"$SECRETLESS_PR\" != \"$SECRETLESS_TRUSTED_REF\" ] || {\n")
    document = replace_once(
        document,
        "          [ -z \"$SCHEMA_DIR\" ] || {\n            echo \"::error::secretless modes do not permit credentialed submodule acquisition\"\n            exit 1\n          }\n",
        "          [ -z \"$SCHEMA_DIR\" ] || {\n            echo \"::error::protected node-ci does not support schema-dir\"\n            exit 1\n          }\n",
    )
    document = replace_once(document, "        with:\n          persist-credentials: false\n", "        with:\n          ref: ${{ inputs.head-sha }}\n          persist-credentials: false\n")
    document = replace_once(document, "          ref: ${{ inputs.head-sha }}\n          persist-credentials: false\n      - name: Reject consumer-controlled npm configuration\n", "          ref: ${{ inputs.head-sha }}\n          persist-credentials: false\n" + verifier_step() + "      - name: Reject consumer-controlled npm configuration\n")
    auxiliary_if = "inputs.secretless-auxiliary-source != ''"
    document = replace_once(document, "      - name: Acquire immutable auxiliary source\n", verifier_step(auxiliary_if) + "      - name: Acquire immutable auxiliary source\n")
    document = replace_once(document, "      - name: Populate verified private dependency cache\n", verifier_step() + "      - name: Populate verified private dependency cache\n")
    document = replace_once(document, "    permissions:\n      contents: read\n    steps:\n", "    permissions:\n      actions: read\n      contents: read\n      pull-requests: read\n    steps:\n")
    checkout = "        with:\n          submodules: ${{ (inputs.secretless-pr || inputs.secretless-trusted-ref) && 'false' || 'recursive' }}\n"
    document = replace_once(document, checkout, "        with:\n          ref: ${{ inputs.head-sha }}\n          submodules: ${{ (inputs.secretless-pr || inputs.secretless-trusted-ref) && 'false' || 'recursive' }}\n")
    rebuild_if = "needs.eligibility.outputs.should-run != 'false' && (inputs.secretless-pr || inputs.secretless-trusted-ref) && inputs.secretless-rebuild-packages != ''"
    plan_if = "needs.eligibility.outputs.should-run != 'false' && (inputs.secretless-pr || inputs.secretless-trusted-ref) && inputs.secretless-ci-script-plan != ''"
    default_if = "needs.eligibility.outputs.should-run != 'false' && (!(inputs.secretless-pr || inputs.secretless-trusted-ref) || inputs.secretless-ci-script-plan == '')"
    document = replace_once(document, "      - name: Rebuild exact approved lifecycle packages without credentials\n", verifier_step(rebuild_if) + "      - name: Rebuild exact approved lifecycle packages without credentials\n")
    document = replace_once(document, "      - name: Run exact credentialless consumer script plan\n", verifier_step(plan_if) + "      - name: Run exact credentialless consumer script plan\n")
    default_commands = """      - run: npm run build
        if: needs.eligibility.outputs.should-run != 'false' && (!(inputs.secretless-pr || inputs.secretless-trusted-ref) || inputs.secretless-ci-script-plan == '')
      - run: npm run typecheck --if-present
        if: needs.eligibility.outputs.should-run != 'false' && (!(inputs.secretless-pr || inputs.secretless-trusted-ref) || inputs.secretless-ci-script-plan == '')
      - run: npm test
        if: needs.eligibility.outputs.should-run != 'false' && (!(inputs.secretless-pr || inputs.secretless-trusted-ref) || inputs.secretless-ci-script-plan == '')
      - run: npm run lint --if-present
        if: needs.eligibility.outputs.should-run != 'false' && (!(inputs.secretless-pr || inputs.secretless-trusted-ref) || inputs.secretless-ci-script-plan == '')
"""
    grouped_default = """      - name: Run default build, typecheck, test, and lint plan
        if: needs.eligibility.outputs.should-run != 'false' && (!(inputs.secretless-pr || inputs.secretless-trusted-ref) || inputs.secretless-ci-script-plan == '')
        run: |
          npm run build
          npm run typecheck --if-present
          npm test
          npm run lint --if-present
"""
    document = replace_once(document, default_commands, verifier_step(default_if) + grouped_default)
    compatibility_if = "needs.eligibility.outputs.should-run != 'false' && (inputs.secretless-pr || inputs.secretless-trusted-ref) && inputs.secretless-compatibility-ranges != ''"
    document = replace_once(document, "      - name: Run runtime-resolved compatibility lanes without credentials\n", verifier_step(compatibility_if) + "      - name: Run runtime-resolved compatibility lanes without credentials\n")
    document = remove_step(document, "Install schema submodule deps")
    for step_name in (
        "Rebuild exact approved lifecycle packages without credentials",
        "Run exact credentialless consumer script plan",
        "Run default build, typecheck, test, and lint plan",
        "Run runtime-resolved compatibility lanes without credentials",
    ):
        document = remove_candidate_credentials(document, step_name)
    document = isolate_candidate_runtime_cache(document)
    return document


if __name__ == "__main__":
    TARGET.write_text(render(), encoding="utf-8")
