#!/usr/bin/env python3
import ast
import copy
import errno
import hashlib
import os
import pathlib
import re
import stat
import subprocess
import tempfile
import threading
import types

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
PROVISION = "Provision trusted compatibility sandbox"
NODE_EXECUTION = "Run runtime-resolved compatibility lanes without credentials"
HOSTED_EXECUTION = "Run namespace-bound compatibility contracts"
HOSTED_GATE = (
    "needs.eligibility.outputs.should-run != 'false' && "
    "(inputs.secretless-pr || inputs.secretless-trusted-ref) && "
    "inputs.secretless-compatibility-ranges != '' && "
    "runner.environment == 'github-hosted'"
)
SECRETLESS_ENV = {
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "",
    "ACTIONS_ID_TOKEN_REQUEST_URL": "",
    "AWS_ACCESS_KEY_ID": "",
    "AWS_SECRET_ACCESS_KEY": "",
    "AWS_SESSION_TOKEN": "",
    "AZURE_CREDENTIALS": "",
    "GH_TOKEN": "",
    "GITHUB_TOKEN": "",
    "GOOGLE_APPLICATION_CREDENTIALS": "",
    "NODE_AUTH_TOKEN": "",
    "NPM_TOKEN": "",
}
PROFILE_PATH = "/usr/share/apparmor/extra-profiles/bwrap-userns-restrict"
APPARMOR_FLOOR = "4.0.1really4.0.1-0ubuntu0.24.04.3"
BOUNDARY_PHASES = (
    "ancestor-directories",
    "usrmerge-parser-link",
    "local-overrides",
    "abi-tree",
    "tunables-tree",
    "bwrap-binary",
    "parser-binary",
    "package-profile",
    "profile-semantics",
    "receipt-recomputation",
    "profile-load",
    "unknown",
)
BOUNDARY_STATUS = {phase: 70 + index for index, phase in enumerate(BOUNDARY_PHASES)}
ISOLATION_REFERENCE = None


class ContractError(RuntimeError):
    pass


def load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def named_step(steps, name, owner):
    matches = [step for step in steps if step.get("name") == name]
    if len(matches) != 1:
        raise ContractError(f"{owner} provisioner missing")
    return matches[0]


def require(source, needle, reason):
    if needle not in source:
        raise ContractError(reason)


def require_count(source, needle, count, reason):
    if source.count(needle) != count:
        raise ContractError(reason)


def extract_probe(source):
    match = re.search(r"(?ms)^probe_bubblewrap\(\) \{\n(?P<body>.*?)^\}", source)
    if match is None:
        raise ContractError("unprivileged namespace probe missing")
    return match.group("body")


def extract_shell_function(source, name):
    match = re.search(rf"(?m)^{re.escape(name)}\(\) (?P<open>[{{(])$", source)
    if match is None:
        raise ContractError(f"{name} shell function missing")
    next_function = re.search(
        r"(?m)^[a-z_][a-z0-9_]*\(\) [({]$", source[match.end() + 1 :]
    )
    candidates = []
    if next_function is not None:
        candidates.append(match.end() + 1 + next_function.start())
    tail = source.find("\ninitial_sandbox_receipt=", match.end())
    if tail >= 0:
        candidates.append(tail)
    if not candidates:
        raise ContractError(f"{name} shell function end missing")
    function = source[match.start() : min(candidates)].rstrip()
    if (match.group("open"), function[-1]) not in (("{", "}"), ("(", ")")):
        raise ContractError(f"{name} shell function delimiter drifted")
    return function


def extract_receipt_mismatch_guard(source):
    start = source.find('if [ "$current_sandbox_receipt" != "$initial_sandbox_receipt" ]; then')
    if start < 0:
        raise ContractError("pre-load receipt mismatch guard missing")
    end = source.find("\n  fi", start)
    if end < 0:
        raise ContractError("pre-load receipt mismatch guard malformed")
    return source[start : end + len("\n  fi")]


def embedded_verifier(source):
    source = extract_shell_function(source, "sandbox_verifier_source")
    marker = "/usr/bin/cat <<'PY'\n"
    if source.count(marker) != 1:
        raise ContractError("embedded filesystem verifier missing")
    verifier = source.split(marker, 1)[1].split("\nPY\n", 1)[0]
    try:
        tree = ast.parse(verifier)
    except SyntaxError as error:
        raise ContractError("embedded filesystem verifier is invalid") from error
    definition_names = {
        "VerificationError",
        "boundary_phase",
        "boundary_diagnostic",
        "boundary_status",
        "validate_metadata",
        "validate_directory",
        "has_security_capability",
        "profile_block",
        "validate_profile_text",
    }
    assignment_names = {"BOUNDARY_PHASES", "BOUNDARY_STATUS"}
    definitions = [
        node
        for node in tree.body
        if (
            isinstance(node, (ast.ClassDef, ast.FunctionDef))
            and node.name in definition_names
        )
        or (
            isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id in assignment_names
                for target in node.targets
            )
        )
    ]
    found_definitions = {
        node.name for node in definitions if isinstance(node, (ast.ClassDef, ast.FunctionDef))
    }
    found_assignments = {
        target.id
        for node in definitions
        if isinstance(node, ast.Assign)
        for target in node.targets
        if isinstance(target, ast.Name)
    }
    if found_definitions != definition_names or found_assignments != assignment_names:
        raise ContractError("embedded filesystem verifier behavior missing")
    namespace = {"errno": errno, "re": re, "stat": stat}
    exec(compile(ast.Module(definitions, type_ignores=[]), "<verifier>", "exec"), namespace)
    return namespace


def require_rejected(call, reason):
    try:
        call()
    except RuntimeError:
        return
    raise ContractError(reason)


def validate_embedded_behavior(source):
    verifier = embedded_verifier(source)
    validate_metadata = verifier["validate_metadata"]
    validate_directory = verifier["validate_directory"]
    has_security_capability = verifier["has_security_capability"]
    validate_profile = verifier["validate_profile_text"]
    verification_error = verifier["VerificationError"]
    boundary_phase = verifier["boundary_phase"]
    boundary_diagnostic = verifier["boundary_diagnostic"]
    boundary_status = verifier["boundary_status"]

    if tuple(verifier["BOUNDARY_PHASES"]) != BOUNDARY_PHASES:
        missing = next(
            phase for phase in BOUNDARY_PHASES if phase not in verifier["BOUNDARY_PHASES"]
        )
        raise ContractError(f"boundary phase allowlist drifted: {missing}")
    if verifier["BOUNDARY_STATUS"] != BOUNDARY_STATUS:
        raise ContractError("boundary phase status mapping drifted")
    for phase in BOUNDARY_PHASES:
        error = verification_error(phase)
        if boundary_phase(error) != phase:
            raise ContractError(f"boundary phase classifier rejected {phase}")
        expected = (
            "::error::trusted compatibility sandbox filesystem boundary unsafe "
            f"phase={phase}"
        )
        if boundary_diagnostic(error) != expected:
            raise ContractError(f"boundary diagnostic drifted for {phase}")
        if boundary_status(error) != BOUNDARY_STATUS[phase]:
            raise ContractError(f"boundary status drifted for {phase}")

    raw_values = (
        "DEPLOY_KEY=bare-deploy-secret",
        "OPENAI_API_KEY=bare-openai-secret",
        '{"token":"json-secret"}',
        "non-allowlisted-exception-sentinel",
    )
    for raw_value in raw_values:
        for error in (RuntimeError(raw_value), verification_error(raw_value)):
            diagnostic = boundary_diagnostic(error)
            if diagnostic != (
                "::error::trusted compatibility sandbox filesystem boundary unsafe "
                "phase=unknown"
            ):
                raise ContractError("unknown boundary fallback drifted")
            if raw_value in diagnostic or boundary_phase(error) != "unknown":
                raise ContractError("boundary diagnostic leaked non-allowlisted exception")

    regular = stat.S_IFREG | 0o755
    metadata = lambda mode, uid=0, gid=0: types.SimpleNamespace(
        st_mode=mode,
        st_uid=uid,
        st_gid=gid,
    )
    validate_metadata(metadata(regular), executable=True)
    require_rejected(
        lambda: validate_metadata(metadata(regular | stat.S_ISUID), executable=True),
        "set-id mode rejection missing",
    )
    require_rejected(
        lambda: validate_metadata(metadata(regular | stat.S_ISGID), executable=True),
        "set-id mode rejection missing",
    )
    require_rejected(
        lambda: validate_metadata(metadata(regular), executable=True, capability_present=True),
        "file capability rejection missing",
    )
    require_rejected(
        lambda: validate_metadata(metadata(regular, uid=1000), executable=True),
        "root ownership verification missing",
    )
    require_rejected(
        lambda: validate_metadata(metadata(regular, gid=1000), executable=True),
        "root group verification missing",
    )
    require_rejected(
        lambda: validate_metadata(metadata(regular | 0o002), executable=True),
        "writable-mode rejection missing",
    )
    require_rejected(
        lambda: validate_metadata(metadata(stat.S_IFREG | 0o644), executable=True),
        "executable-mode verification missing",
    )
    require_rejected(
        lambda: validate_metadata(metadata(regular), executable=False),
        "profile executable-mode rejection missing",
    )
    directory = lambda mode, uid=0, gid=0: types.SimpleNamespace(
        st_mode=mode,
        st_uid=uid,
        st_gid=gid,
    )
    validate_directory(directory(stat.S_IFDIR | 0o755))
    require_rejected(
        lambda: validate_directory(directory(stat.S_IFLNK | 0o755)),
        "include-tree symlink rejection missing",
    )
    require_rejected(
        lambda: validate_directory(directory(stat.S_IFDIR | 0o755, uid=1000)),
        "include-tree root ownership verification missing",
    )
    require_rejected(
        lambda: validate_directory(directory(stat.S_IFDIR | 0o777)),
        "include-tree writable-mode rejection missing",
    )
    verifier["os"] = types.SimpleNamespace(
        getxattr=lambda _descriptor, _name: b"capability",
    )
    if not has_security_capability(7):
        raise ContractError("capability xattr probe behavior drifted")

    def missing_xattr(_descriptor, _name):
        raise OSError(errno.ENODATA, "absent")

    verifier["os"] = types.SimpleNamespace(getxattr=missing_xattr)
    if has_security_capability(7):
        raise ContractError("capability xattr probe behavior drifted")

    valid_profile = """abi <abi/4.0>,
profile bwrap /usr/bin/bwrap flags=(attach_disconnected) {
  allow px /** -> bwrap//&unpriv_bwrap,
}
profile unpriv_bwrap flags=(attach_disconnected) {
  allow pix /** -> &unpriv_bwrap,
  audit deny capability,
}
"""
    validate_profile(valid_profile)
    denial_moved_to_parent = valid_profile.replace(
        "  allow px /** -> bwrap//&unpriv_bwrap,",
        "  allow px /** -> bwrap//&unpriv_bwrap,\n  audit deny capability,",
    )
    child_denial = denial_moved_to_parent.rfind("  audit deny capability,\n")
    denial_moved_to_parent = (
        denial_moved_to_parent[:child_denial]
        + denial_moved_to_parent[child_denial + len("  audit deny capability,\n"):]
    )
    unsafe_profiles = {
        "parent transition is not block-bound": valid_profile.replace(
            "  allow px /** -> bwrap//&unpriv_bwrap,\n}\nprofile unpriv_bwrap",
            "}\nprofile unpriv_bwrap",
        ).replace(
            "  allow pix /** -> &unpriv_bwrap,",
            "  allow px /** -> bwrap//&unpriv_bwrap,\n  allow pix /** -> &unpriv_bwrap,",
        ),
        "child denial is not block-bound": denial_moved_to_parent,
        "recursive transition is not child-bound": valid_profile.replace(
            "  allow px /** -> bwrap//&unpriv_bwrap,",
            "  allow px /** -> bwrap//&unpriv_bwrap,\n  allow pix /** -> &unpriv_bwrap,",
        ).replace("  allow pix /** -> &unpriv_bwrap,\n  audit", "  audit", 1),
        "child capability allowance accepted": valid_profile.replace(
            "  audit deny capability,",
            "  audit deny capability,\n  allow capability sys_admin,",
        ),
        "implicit child capability allowance accepted": valid_profile.replace(
            "  audit deny capability,",
            "  audit deny capability,\n  capability sys_admin,",
        ),
        "audited child capability allowance accepted": valid_profile.replace(
            "  audit deny capability,",
            "  audit deny capability,\n  audit capability sys_admin,",
        ),
        "owner child capability allowance accepted": valid_profile.replace(
            "  audit deny capability,",
            "  audit deny capability,\n  owner capability sys_admin,",
        ),
        "audit-owner child capability allowance accepted": valid_profile.replace(
            "  audit deny capability,",
            "  audit deny capability,\n  audit owner capability sys_admin,",
        ),
    }
    for reason, profile in unsafe_profiles.items():
        require_rejected(lambda profile=profile: validate_profile(profile), reason)


def validate_isolated_python(source):
    global ISOLATION_REFERENCE

    require_count(source, "/usr/bin/python3 -I -", 2, "isolated Python boundary drifted")
    require(
        source,
        '/usr/bin/python3 -I -c "$supervisor_source"',
        "isolated root supervisor Python boundary missing",
    )
    require(
        source,
        "sandbox_verifier_source | /usr/bin/sudo --non-interactive /usr/bin/env -i",
        "credentialless privileged loader boundary drifted",
    )

    with tempfile.TemporaryDirectory(prefix="verjson-python-isolation-") as fixture:
        fixture_path = pathlib.Path(fixture)
        sentinel = fixture_path / "module-hijack-ran"
        raw_secret = "bare-module-hijack-secret"
        module_source = (
            f"open({str(sentinel)!r}, 'a').write(__name__ + '\\n')\n"
            f"print({raw_secret!r})\n"
            "raise RuntimeError('cwd module hijack executed')\n"
        )
        for module in ("re", "hashlib", "subprocess", "pathlib"):
            (fixture_path / f"{module}.py").write_text(module_source, encoding="utf-8")
        command = (
            "/usr/bin/env",
            "-i",
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME=/nonexistent",
            "/usr/bin/python3",
            "-I",
            "-",
        )
        result = subprocess.run(
            command,
            input="import hashlib, pathlib, re, subprocess\nprint('receipt-ok')\n",
            cwd=fixture,
            env={
                **os.environ,
                "DEPLOY_KEY": raw_secret,
                "OPENAI_API_KEY": raw_secret,
                "PYTHONPATH": fixture,
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0 or result.stdout != "receipt-ok\n" or result.stderr:
            raise ContractError("isolated Python module-hijack control failed")
        if sentinel.exists() or raw_secret in result.stdout or raw_secret in result.stderr:
            raise ContractError("cwd Python module hijack crossed isolated boundary")

        if ISOLATION_REFERENCE is None:
            ISOLATION_REFERENCE = source
        if source != ISOLATION_REFERENCE:
            return

        verifier_result = subprocess.run(
            command + ("verify", "/unexpected-profile"),
            input=source.split("/usr/bin/cat <<'PY'\n", 1)[1].split("\nPY\n", 1)[0],
            cwd=fixture,
            env={
                **os.environ,
                "DEPLOY_KEY": raw_secret,
                "OPENAI_API_KEY": raw_secret,
                "PYTHONPATH": fixture,
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        expected_diagnostic = (
            "::error::trusted compatibility sandbox verifier invocation is unsafe\n"
        )
        if verifier_result.returncode == 0 or verifier_result.stderr != expected_diagnostic:
            raise ContractError("embedded isolated verifier control failed")
        if (
            sentinel.exists()
            or raw_secret in verifier_result.stdout
            or raw_secret in verifier_result.stderr
        ):
            raise ContractError("embedded verifier import hijack crossed isolated boundary")

        loader_result = subprocess.run(
            (
                "/usr/bin/env",
                "-i",
                "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME=/nonexistent",
                f"EXPECTED_SANDBOX_RECEIPT={raw_secret}",
                "/usr/bin/python3",
                "-I",
                "-",
                "load",
                PROFILE_PATH,
            ),
            input=source.split("/usr/bin/cat <<'PY'\n", 1)[1].split("\nPY\n", 1)[0],
            cwd=fixture,
            env={
                **os.environ,
                "DEPLOY_KEY": raw_secret,
                "OPENAI_API_KEY": raw_secret,
                "PYTHONPATH": fixture,
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if loader_result.returncode != BOUNDARY_STATUS["receipt-recomputation"]:
            raise ContractError("embedded loader fixed status control failed")
        if loader_result.stdout or loader_result.stderr or sentinel.exists():
            raise ContractError("embedded loader emitted raw output")
        if raw_secret in loader_result.stdout or raw_secret in loader_result.stderr:
            raise ContractError("embedded loader leaked raw secret")


def validate_shell_diagnostic_filter(source):
    if source != ISOLATION_REFERENCE:
        return

    emit_function = extract_shell_function(source, "emit_verifier_diagnostic")
    verify_function = extract_shell_function(source, "verify_sandbox_files")
    receipt = "a" * 64
    fixture_function = f'''sandbox_verifier_source() {{
  case "$DIAG_FIXTURE" in
    receipt)
      printf '%s\n' 'print("{receipt}")'
      ;;
    allowlisted)
      printf '%s\n' 'import sys' 'sys.stderr.write("::error::trusted compatibility sandbox filesystem boundary unsafe phase=abi-tree\\n")' 'raise SystemExit(1)'
      ;;
    syntax-secret)
      printf '%s\n' 'this is not python OPENAI_API_KEY_SYNTAX_SECRET'
      ;;
    secret-stderr)
      printf '%s\n' 'import sys' 'sys.stderr.write("{{\\"token\\":\\"JSON_TOKEN_SECRET\\"}}\\n")' 'raise SystemExit(1)'
      ;;
    secret-stdout)
      printf '%s\n' 'import sys' 'print("BARE_STDOUT_SECRET")' 'raise SystemExit(1)'
      ;;
    success-with-stderr)
      printf '%s\n' 'import sys' 'print("{receipt}")' 'sys.stderr.write("SUCCESS_STDERR_SECRET\\n")'
      ;;
    producer-secret)
      printf '%s\n' "$DEPLOY_KEY" >&2
      return 1
      ;;
  esac
}}'''

    def run_fixture(fixture, function=verify_function):
        script = "\n".join((
            "set -uo pipefail",
            f"profile_path='{PROFILE_PATH}'",
            emit_function,
            function,
            fixture_function,
            "verify_sandbox_files",
        ))
        return subprocess.run(
            ["/usr/bin/bash", "-c", script],
            env={
                **os.environ,
                "DIAG_FIXTURE": fixture,
                "DEPLOY_KEY": "DEPLOY_KEY_PRODUCER_SECRET",
                "OPENAI_API_KEY": "OPENAI_API_KEY_ENV_SECRET",
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    success = run_fixture("receipt")
    if success.returncode != 0 or success.stdout != f"{receipt}\n" or success.stderr:
        raise ContractError("verifier receipt filter control failed")

    allowlisted = run_fixture("allowlisted")
    expected_abi = (
        "::error::trusted compatibility sandbox filesystem boundary unsafe "
        "phase=abi-tree\n"
    )
    if allowlisted.returncode == 0 or allowlisted.stdout or allowlisted.stderr != expected_abi:
        raise ContractError("verifier allowlisted diagnostic replay failed")

    secrets = (
        "OPENAI_API_KEY_SYNTAX_SECRET",
        "JSON_TOKEN_SECRET",
        "BARE_STDOUT_SECRET",
        "SUCCESS_STDERR_SECRET",
        "DEPLOY_KEY_PRODUCER_SECRET",
        "OPENAI_API_KEY_ENV_SECRET",
        "/missing/python3",
    )
    expected_unknown = (
        "::error::trusted compatibility sandbox filesystem boundary unsafe "
        "phase=unknown\n"
    )
    for fixture in (
        "syntax-secret",
        "secret-stderr",
        "secret-stdout",
        "success-with-stderr",
        "producer-secret",
    ):
        result = run_fixture(fixture)
        if result.returncode == 0 or result.stdout or result.stderr != expected_unknown:
            raise ContractError(f"verifier shell filter failed for {fixture}")
        if any(secret in result.stdout or secret in result.stderr for secret in secrets):
            raise ContractError(f"verifier shell filter leaked {fixture}")

    missing_interpreter = run_fixture(
        "receipt",
        verify_function.replace("/usr/bin/python3", "/missing/python3", 1),
    )
    if (
        missing_interpreter.returncode == 0
        or missing_interpreter.stdout
        or missing_interpreter.stderr != expected_unknown
        or any(
            secret in missing_interpreter.stdout or secret in missing_interpreter.stderr
            for secret in secrets
        )
    ):
        raise ContractError("verifier interpreter failure escaped fixed filter")

    mismatch_guard = extract_receipt_mismatch_guard(source)
    mismatch = subprocess.run(
        [
            "/usr/bin/bash",
            "-c",
            "\n".join((
                "current_sandbox_receipt=current",
                "initial_sandbox_receipt=initial",
                mismatch_guard,
            )),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    expected_receipt = (
        "::error::trusted compatibility sandbox filesystem boundary unsafe "
        "phase=receipt-recomputation\n"
    )
    if mismatch.returncode == 0 or mismatch.stdout or mismatch.stderr != expected_receipt:
        raise ContractError("pre-load receipt mismatch diagnostic drifted")


def validate_root_supervisor_boundary(source):
    if source != ISOLATION_REFERENCE:
        return

    verify_function = extract_shell_function(source, "verify_sandbox_files")
    production_digest = re.search(r"'([0-9a-f]{64})'", verify_function)
    if production_digest is None:
        raise ContractError("verifier source digest binding missing")
    verifier = source.split("/usr/bin/cat <<'PY'\n", 1)[1].split("\nPY\n}", 1)[0] + "\n"
    if hashlib.sha256(verifier.encode("utf-8")).hexdigest() != production_digest.group(1):
        raise ContractError("verifier source digest binding drifted")

    emit_function = extract_shell_function(source, "emit_verifier_diagnostic")
    supervisor_function = extract_shell_function(source, "sandbox_supervisor_source")

    receipt = b"a" * 64
    expected_unknown = (
        b"::error::trusted compatibility sandbox filesystem boundary unsafe "
        b"phase=unknown\n"
    )
    expected_abi = (
        b"::error::trusted compatibility sandbox filesystem boundary unsafe "
        b"phase=abi-tree\n"
    )
    secrets = (
        b"DEPLOY_KEY_PRODUCER_SECRET",
        b"OPENAI_API_KEY_ENV_SECRET",
        b"JSON_TOKEN_SECRET",
        b"BARE_SENTINEL_TEXT",
        b"/missing/python3",
        b"ignored null byte",
    )
    fixture_function = r'''sandbox_verifier_source() {
      if [ -n "${FIXTURE_PRODUCER_STDERR:-}" ]; then
        printf '%s\n' "$FIXTURE_PRODUCER_STDERR" >&2
      fi
      printf '%s\n' "$FIXTURE_SOURCE"
      return "${FIXTURE_PRODUCER_STATUS:-0}"
    }'''

    def python_source(data, status, delay=0):
        return (
            "import sys, time\n"
            f"time.sleep({delay!r})\n"
            f"sys.stdout.buffer.write({data!r})\n"
            "sys.stdout.buffer.flush()\n"
            f"raise SystemExit({status})"
        )

    def run_fixture(
        data,
        status,
        *,
        producer_status=0,
        producer_stderr="",
        selected_supervisor=supervisor_function,
        selected_verify=verify_function,
        attacker=False,
        source_override=None,
    ):
        fixture_source = source_override or python_source(data, status, 0.15 if attacker else 0)
        if attacker:
            fixture_source += "\n# VERJSON_SUPERVISOR_FD_INJECTION_CANARY"
        fixture_digest = hashlib.sha256((fixture_source + "\n").encode("utf-8")).hexdigest()
        selected_verify = selected_verify.replace(production_digest.group(1), fixture_digest)
        with tempfile.TemporaryDirectory(prefix="verjson-supervisor-boundary-") as fixture:
            runner_temp = pathlib.Path(fixture) / "runner-temp"
            runner_temp.mkdir(mode=0o700)
            stop = threading.Event()
            attacker_error = []
            fd_targets_seen = []

            def attack_paths():
                attack_root = runner_temp / "verjson-sandbox-verifier.attacker"
                seed = runner_temp / "attacker-seed"
                try:
                    seed.write_bytes(b"BARE_SENTINEL_TEXT")
                    while not stop.is_set():
                        if attack_root.is_symlink() or attack_root.is_file():
                            attack_root.unlink(missing_ok=True)
                        attack_root.mkdir(exist_ok=True)
                        for name in ("raw", "receipt"):
                            target = attack_root / name
                            target.unlink(missing_ok=True)
                            os.symlink(seed, target)
                            target.unlink(missing_ok=True)
                            os.link(seed, target)
                            target.write_bytes(b"JSON_TOKEN_SECRET")
                            target.unlink(missing_ok=True)
                        attack_root.rmdir()
                        os.symlink(runner_temp, attack_root)
                        attack_root.unlink()
                        for process_dir in pathlib.Path("/proc").glob("[0-9]*"):
                            try:
                                command = (process_dir / "cmdline").read_bytes()
                                if b"VERJSON_SUPERVISOR_FD_INJECTION_CANARY" not in command:
                                    continue
                                fd_targets_seen.append(process_dir.name)
                                descriptor = os.open(
                                    process_dir / "fd/0",
                                    os.O_WRONLY | os.O_NONBLOCK,
                                )
                                try:
                                    os.write(
                                        descriptor,
                                        b'import sys; print("b" * 64); sys.exit(0)\n',
                                    )
                                finally:
                                    os.close(descriptor)
                            except (OSError, PermissionError):
                                pass
                except BaseException as error:
                    attacker_error.append(error)

            thread = None
            if attacker:
                thread = threading.Thread(target=attack_paths, daemon=True)
                thread.start()
            script = "\n".join(
                (
                    "set -uo pipefail",
                    f"profile_path='{PROFILE_PATH}'",
                    emit_function,
                    selected_supervisor,
                    selected_verify,
                    fixture_function,
                    "verify_sandbox_files",
                )
            )
            try:
                result = subprocess.run(
                    ["/usr/bin/bash", "-c", script],
                    env={
                        **os.environ,
                        "RUNNER_TEMP": str(runner_temp),
                        "FIXTURE_SOURCE": fixture_source,
                        "FIXTURE_PRODUCER_STATUS": str(producer_status),
                        "FIXTURE_PRODUCER_STDERR": producer_stderr,
                        "DEPLOY_KEY": "DEPLOY_KEY_PRODUCER_SECRET",
                        "OPENAI_API_KEY": "OPENAI_API_KEY_ENV_SECRET",
                    },
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                    timeout=10,
                )
            finally:
                stop.set()
                if thread is not None:
                    thread.join(timeout=2)
            if thread is not None and thread.is_alive():
                raise ContractError("same-UID path attacker did not stop")
            if attacker_error:
                raise ContractError("same-UID path attacker fixture failed")
            if attacker and not fd_targets_seen:
                raise ContractError("same-UID stdin attacker did not observe verifier child")
            return result

    success = run_fixture(receipt + b"\n", 0)
    if success.returncode != 0 or success.stdout != receipt + b"\n" or success.stderr:
        raise ContractError("root supervisor exact receipt classification failed")
    attacked_success = run_fixture(receipt + b"\n", 0, attacker=True)
    if (
        attacked_success.returncode != 0
        or attacked_success.stdout != receipt + b"\n"
        or attacked_success.stderr
    ):
        raise ContractError("same-UID path attacker influenced supervisor receipt")
    attacked_diagnostic = run_fixture(expected_abi, 1, attacker=True)
    if (
        attacked_diagnostic.returncode == 0
        or attacked_diagnostic.stdout
        or attacked_diagnostic.stderr != expected_abi
    ):
        raise ContractError("same-UID path attacker influenced supervisor diagnostic")

    actual_failure_source = verifier.rstrip("\n").replace(
        "receipt = verify_system(sys.argv[2])",
        'raise VerificationError("abi-tree")',
        1,
    )
    actual_failure = run_fixture(
        b"",
        0,
        source_override=actual_failure_source,
    )
    if (
        actual_failure.returncode == 0
        or actual_failure.stdout
        or actual_failure.stderr != expected_abi
    ):
        raise ContractError("actual embedded verifier phase was lost by supervisor")

    malformed = {
        "receipt without newline": (receipt, 0, 0, ""),
        "receipt with trailing blank record": (receipt + b"\n\n", 0, 0, ""),
        "receipt with extra byte": (receipt + b"x\n", 0, 0, ""),
        "receipt with nul prefix": (b"\0" + receipt + b"\n", 0, 0, ""),
        "receipt with nul suffix": (receipt + b"\n\0", 0, 0, ""),
        "receipt with interleaved nul": (receipt[:32] + b"\0" + receipt[32:] + b"\n", 0, 0, ""),
        "diagnostic without newline": (expected_abi[:-1], 1, 0, ""),
        "diagnostic with trailing blank record": (expected_abi + b"\n", 1, 0, ""),
        "diagnostic with nul prefix": (b"\0" + expected_abi, 1, 0, ""),
        "diagnostic with nul suffix": (expected_abi + b"\0", 1, 0, ""),
        "receipt with failing status": (receipt + b"\n", 1, 0, ""),
        "diagnostic with wrong failure status": (expected_abi, 2, 0, ""),
        "diagnostic with success status": (expected_abi, 0, 0, ""),
        "secret stdout": (b"JSON_TOKEN_SECRET\n", 1, 0, ""),
        "producer stderr": (b"", 1, 1, "DEPLOY_KEY_PRODUCER_SECRET"),
        "success with secret stderr": (receipt + b"\n", 0, 0, "BARE_SENTINEL_TEXT"),
    }
    for reason, (data, status, producer_status, producer_stderr) in malformed.items():
        result = run_fixture(
            data,
            status,
            producer_status=producer_status,
            producer_stderr=producer_stderr,
        )
        if result.returncode == 0 or result.stdout or result.stderr != expected_unknown:
            raise ContractError(f"root supervisor accepted {reason}")
        if any(secret in result.stdout or secret in result.stderr for secret in secrets):
            raise ContractError(f"root supervisor leaked {reason}")

    missing_interpreter = run_fixture(
        receipt + b"\n",
        0,
        selected_verify=verify_function.replace("/usr/bin/python3", "/missing/python3", 1),
    )
    broken_supervisor = run_fixture(
        receipt + b"\n",
        0,
        selected_supervisor=supervisor_function.replace("import hashlib", "this is not python", 1),
    )
    for reason, result in (
        ("supervisor interpreter", missing_interpreter),
        ("supervisor pre-program", broken_supervisor),
    ):
        if result.returncode == 0 or result.stdout or result.stderr != expected_unknown:
            raise ContractError(f"{reason} failure escaped fixed diagnostic")
        if any(secret in result.stdout or secret in result.stderr for secret in secrets):
            raise ContractError(f"{reason} failure leaked raw output")

def validate_source(source):
    normalized_source = "\n".join(line.strip() for line in source.splitlines())
    forbidden = {
        "apparmor_restrict_unprivileged_userns": "system-wide userns override forbidden",
        "unprivileged_userns_clone": "system-wide userns override forbidden",
        "--unshare-user-try": "user namespace fallback forbidden",
        "chmod u+s": "setuid fallback forbidden",
        "chmod 4": "setuid fallback forbidden",
        "curl ": "downloaded AppArmor profile forbidden",
        "wget ": "downloaded AppArmor profile forbidden",
    }
    for needle, reason in forbidden.items():
        if needle in source:
            raise ContractError(reason)
    if re.search(r"(?m)^\s*(?:sudo|/usr/bin/sudo)\s+sysctl\b", source):
        raise ContractError("system-wide userns override forbidden")

    probe = extract_probe(source)
    if "/usr/bin/sudo" in probe or re.search(r"(?m)^\s*sudo\b", probe):
        raise ContractError("privileged bubblewrap probe forbidden")

    require_count(
        source,
        "/usr/bin/sudo --non-interactive /usr/bin/env -i",
        4,
        "absolute sudo or environment scrubber drifted",
    )
    require_count(source, "/usr/bin/apt-get", 2, "absolute apt path drifted")
    require(
        source,
        "/usr/bin/cat <<'PY'",
        "embedded verifier source boundary drifted",
    )
    require(source, "/usr/bin/python3 -I - load \"$profile_path\"", "absolute Python loader path drifted")
    require(
        source,
        "sandbox_supervisor_source() {",
        "root verifier supervisor source missing",
    )
    require(
        source,
        "hashlib.sha256(verifier_source).hexdigest() != expected_digest",
        "verifier source digest binding missing",
    )
    require(
        source,
        "ba649728453d0971df08421476a724ac56dcfc21a95aaa34f1a582da484265ec",
        "verifier source digest binding drifted",
    )
    require(
        source,
        "os.geteuid() != 0",
        "root supervisor privilege boundary missing",
    )
    require(
        source,
        "sys.stdin.buffer.read(1048577)",
        "root supervisor source bound missing",
    )
    if re.search(
        r'\(\s*"/usr/bin/python3",\s*"-I",\s*"-c",\s*verifier_text,\s*"verify",\s*profile_path,\s*\)',
        source,
    ) is None:
        raise ContractError("absolute unprivileged verifier child path drifted")
    require(source, 'verifier_source.decode("utf-8", "strict")', "verifier static source decoding missing")
    require(
        source,
        "stdin=subprocess.DEVNULL,\n        stdout=subprocess.PIPE,\n        stderr=subprocess.STDOUT,",
        "verifier immutable argv and in-memory output boundary missing",
    )
    require(source, 'cwd="/"', "verifier fixed working directory missing")
    require(source, "timeout=60", "verifier execution bound missing")
    require(
        source,
        "timeout=60,\n        check=False,",
        "verifier explicit status capture missing",
    )
    require(source, "close_fds=True", "verifier descriptor isolation missing")
    require(source, "start_new_session=True", "verifier process isolation missing")
    require(
        source,
        'env={\n            "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",\n            "HOME": "/nonexistent",\n        }',
        "verifier child fixed environment missing",
    )
    require(
        source,
        'status == 0 and re.fullmatch(rb"[0-9a-f]{64}\\n", output)',
        "supervisor exact receipt status binding missing",
    )
    require(
        source,
        "status == 1 and output in diagnostic_status",
        "supervisor exact diagnostic status binding missing",
    )
    require(
        source,
        "status = diagnostic_status[output]",
        "supervisor diagnostic phase mapping missing",
    )
    require(
        source,
        "/usr/bin/sudo --non-interactive /usr/bin/env -i",
        "root supervisor sudo boundary missing",
    )
    require(
        source,
        '/usr/bin/python3 -I -c "$supervisor_source"',
        "isolated root supervisor Python boundary missing",
    )
    require(
        source,
        "{ sandbox_verifier_source 2>&1 |",
        "trusted verifier source pipe missing",
    )
    require(
        source,
        "2>/dev/null",
        "outer supervisor failure suppression missing",
    )
    require(
        source,
        '[[ "$supervisor_output" =~ ^[0-9a-f]{64}$ ]]',
        "sanitized supervisor receipt filter missing",
    )
    require(
        source,
        '"$supervisor_output" = "::error::trusted compatibility sandbox filesystem boundary unsafe phase=$supervisor_phase"',
        "sanitized supervisor diagnostic filter missing",
    )
    forbidden_capture_paths = (
        "validate_verifier_capture",
        "capture_file",
        "receipt_file",
        "capture_dir",
        "cleanup_verifier_capture",
        "verjson-sandbox-verifier.XXXXXX",
        '"$RUNNER_TEMP/verjson-sandbox-verifier',
    )
    for forbidden_path in forbidden_capture_paths:
        if forbidden_path in source:
            raise ContractError("runner-owned verifier capture path remains")
    for forbidden_path in ("open(", "tempfile", "pathlib", '"/tmp'):
        supervisor_start = source.find("sandbox_supervisor_source() {")
        supervisor_end = source.find("\nverify_sandbox_files() (", supervisor_start)
        if forbidden_path in source[supervisor_start:supervisor_end]:
            raise ContractError("root supervisor filesystem path introduced")
    for forbidden_path in ("RUNNER_TEMP", "mktemp", "unlink", "rmdir"):
        if forbidden_path in source:
            raise ContractError("runner-owned verifier capture path remains")
    validate_isolated_python(source)
    validate_root_supervisor_boundary(source)
    require(
        source,
        "echo '::error::trusted compatibility sandbox filesystem boundary unsafe phase=unknown' >&2",
        "verifier unknown diagnostic fallback missing",
    )
    require(
        source,
        'echo "::error::trusted compatibility sandbox filesystem boundary unsafe phase=receipt-recomputation" >&2',
        "pre-load receipt mismatch diagnostic drifted",
    )
    if "trusted compatibility sandbox filesystem boundary changed" in source:
        raise ContractError("legacy receipt mismatch diagnostic remains")
    require(
        source,
        "/usr/bin/python3 -I - load \"$profile_path\" >/dev/null 2>&1 || loader_status=$?",
        "loader raw stderr suppression missing",
    )
    require_count(
        source,
        "APT::Get::AllowUnauthenticated=false",
        2,
        "unauthenticated apt rejection drifted",
    )
    require_count(
        source,
        "Acquire::AllowInsecureRepositories=false",
        2,
        "insecure apt repository rejection drifted",
    )
    require(
        source,
        "::error::trusted compatibility sandbox package index acquisition failed",
        "fixed package-index diagnostic missing",
    )
    require(
        source,
        "::error::trusted compatibility sandbox package acquisition failed",
        "fixed package-acquisition diagnostic missing",
    )
    require(source, "update >/dev/null 2>&1", "signed apt index update command drifted")
    for command in ("full-upgrade", "dist-upgrade", " upgrade"):
        if command in source:
            raise ContractError("broad apt upgrade forbidden")
    require(
        source,
        "install --yes --no-install-recommends \\\n  apparmor apparmor-profiles bubblewrap >/dev/null 2>&1",
        "signed compatibility sandbox package acquisition missing",
    )

    require(
        source,
        "verify_package_floor bubblewrap '0.9.0-1build1'",
        "bubblewrap package version floor drifted",
    )
    require(
        source,
        f"verify_package_floor apparmor '{APPARMOR_FLOOR}'",
        "AppArmor package version floor drifted",
    )
    require(
        source,
        f"verify_package_floor apparmor-profiles '{APPARMOR_FLOOR}'",
        "AppArmor profiles package version floor drifted",
    )
    require(
        source,
        "/usr/bin/dpkg-query -W -f='${db:Status-Abbrev} ${Version}\\n'",
        "absolute package status verification drifted",
    )
    require(
        source,
        "/usr/bin/dpkg --compare-versions",
        "absolute package version verification drifted",
    )
    require(
        source,
        "/usr/bin/dpkg-query -S /usr/bin/bwrap",
        "bubblewrap package ownership verification missing",
    )
    require(
        source,
        "/usr/bin/dpkg-query -S /sbin/apparmor_parser",
        "AppArmor parser package ownership verification missing",
    )
    require(
        source,
        '/usr/bin/dpkg-query -S "$profile_path"',
        "AppArmor profile package ownership verification missing",
    )
    require(
        source,
        f"profile_path='{PROFILE_PATH}'",
        "restrictive AppArmor profile path drifted",
    )
    require(source, "verify_system(sys.argv[2])", "profile verifier is not bound to package-owned path")

    require(
        normalized_source,
        'open_verified_file(\n"/sbin/apparmor_parser",\nexecutable=True,',
        "absolute AppArmor parser verifier drifted",
    )
    require(
        normalized_source,
        'read_verified_file(\n"/usr/bin/bwrap",\nexecutable=True,',
        "absolute bubblewrap verifier drifted",
    )
    require(source, "flags |= os.O_NOFOLLOW", "symlink rejection missing")
    require(
        source,
        "not stat.S_ISREG(metadata.st_mode)",
        "regular-file verification missing",
    )
    require(source, "metadata.st_uid != 0", "root ownership verification missing")
    require(source, "metadata.st_gid != 0", "root group verification missing")
    require(source, "metadata.st_mode & 0o022", "writable-mode rejection missing")
    require(source, "stat.S_ISUID | stat.S_ISGID", "set-id mode rejection missing")
    require(source, "executable and not metadata.st_mode & 0o111", "executable-mode verification missing")
    require(source, "not executable and metadata.st_mode & 0o111", "profile executable-mode rejection missing")
    require(
        source,
        '"/etc/apparmor.d/local/bwrap-userns-restrict"',
        "bwrap local profile override rejection missing",
    )
    require(
        source,
        '"/etc/apparmor.d/local/unpriv_bwrap"',
        "child local profile override rejection missing",
    )
    require(
        source,
        "os.lstat(override)",
        "local profile override symlink rejection missing",
    )
    require(
        source,
        'verify_include_tree("/etc/apparmor.d/tunables", "tunables-tree")',
        "AppArmor tunables tree verification missing",
    )
    require_count(source, '"/etc/apparmor.d/abi"', 2, "AppArmor ABI include tree verification missing")
    require(source, "directories.sort()", "AppArmor include directory ordering missing")
    require(source, "files.sort()", "AppArmor include file ordering missing")
    require(source, "followlinks=False", "AppArmor include symlink rejection missing")
    require(source, 'os.lstat("/sbin")', "usrmerge parser ancestry verification missing")
    require(source, "or sbin_target not in", "usrmerge parser target verification missing")
    require(source, "initial_sandbox_receipt=", "initial filesystem receipt missing")
    require(source, "current_sandbox_receipt=", "pre-parse filesystem recheck missing")
    require_count(source, '"$(verify_sandbox_files)"', 2, "filesystem recheck count drifted")
    require(source, '"$current_sandbox_receipt" != "$initial_sandbox_receipt"', "filesystem identity binding missing")
    require(source, "bind_parser=True", "descriptor-bound parser verification missing")
    require(source, 're.fullmatch(r"[0-9a-f]{64}", expected_receipt)', "loader receipt format guard missing")
    require(source, "receipt != expected_receipt", "loader receipt comparison missing")
    require(source, 'EXPECTED_SANDBOX_RECEIPT="$initial_sandbox_receipt"', "loader expected receipt binding missing")
    require(source, 'sys.argv[2] != "/usr/share/apparmor/extra-profiles/bwrap-userns-restrict"', "loader static profile path binding missing")
    require(source, "os.set_inheritable(profile_descriptor, True)", "profile descriptor inheritance missing")
    require(source, "os.set_inheritable(parser_descriptor, True)", "parser descriptor inheritance missing")
    require(normalized_source, "os.execve(\nparser_descriptor,", "parser descriptor execution missing")
    require(source, 'f"/proc/self/fd/{profile_descriptor}"', "profile descriptor execution path missing")
    if '/sbin/apparmor_parser --replace "$profile_path"' in source:
        raise ContractError("parser pathname reopen forbidden")
    require(source, '[path, "--version"]', "bubblewrap executable check missing")
    require(
        source,
        "stderr=subprocess.DEVNULL",
        "bubblewrap verifier stderr suppression missing",
    )
    require(source, "< (0, 9, 0)", "bubblewrap executable version floor drifted")
    phase_wiring = {
        "ancestor-directories": 'raise VerificationError("ancestor-directories") from None',
        "usrmerge-parser-link": 'raise VerificationError("usrmerge-parser-link") from None',
        "local-overrides": 'raise VerificationError("local-overrides") from None',
        "abi-tree": 'verify_include_tree("/etc/apparmor.d/abi", "abi-tree")',
        "tunables-tree": 'verify_include_tree("/etc/apparmor.d/tunables", "tunables-tree")',
        "bwrap-binary": 'raise VerificationError("bwrap-binary")',
        "parser-binary": 'raise VerificationError("parser-binary") from None',
        "package-profile": 'raise VerificationError("package-profile") from None',
        "profile-semantics": 'raise VerificationError("profile-semantics") from None',
        "receipt-recomputation": 'raise VerificationError("receipt-recomputation")',
        "profile-load": 'raise VerificationError("profile-load") from None',
    }
    for phase, marker in phase_wiring.items():
        require(source, marker, f"boundary phase wiring missing for {phase}")
    for phase in BOUNDARY_PHASES:
        require(source, f'"{phase}"', f"boundary phase allowlist missing {phase}")

    loader_phase_mappings = {
        "ancestor-directories": "70) loader_phase='ancestor-directories' ;;",
        "usrmerge-parser-link": "71) loader_phase='usrmerge-parser-link' ;;",
        "local-overrides": "72) loader_phase='local-overrides' ;;",
        "abi-tree": "73) loader_phase='abi-tree' ;;",
        "tunables-tree": "74) loader_phase='tunables-tree' ;;",
        "bwrap-binary": "75) loader_phase='bwrap-binary' ;;",
        "parser-binary": "76) loader_phase='parser-binary' ;;",
        "package-profile": "77) loader_phase='package-profile' ;;",
        "profile-semantics": "78) loader_phase='profile-semantics' ;;",
        "receipt-recomputation": "79) loader_phase='receipt-recomputation' ;;",
        "profile-load": "1|80) loader_phase='profile-load' ;;",
        "unknown": "81) loader_phase='unknown' ;;",
    }
    for phase, marker in loader_phase_mappings.items():
        require(source, marker, f"loader phase mapping missing for {phase}")
    require(source, "*) loader_phase='unknown' ;;", "loader unknown status fallback missing")
    require(
        source,
        "/usr/bin/python3 -I - load \"$profile_path\" >/dev/null 2>&1 || loader_status=$?",
        "loader raw stderr suppression missing",
    )
    require(
        source,
        "::error::trusted compatibility sandbox filesystem boundary unsafe phase=$loader_phase",
        "fixed loader boundary diagnostic missing",
    )
    semantic_guards = {
        '"abi <abi/4.0>,"': "AppArmor ABI semantic guard missing",
        "profile unpriv_bwrap flags=": "restricted child profile guard missing",
        'r"flags=\\([^)]*\\bunconfined\\b"': "unconfined profile rejection missing",
        "profile bwrap /usr/bin/bwrap flags=": "absolute bwrap profile attachment guard missing",
    }
    for needle, reason in semantic_guards.items():
        require(source, needle, reason)
    validate_embedded_behavior(source)

    probe_requirements = {
        "/usr/bin/env -i": "credentialless probe environment missing",
        "/usr/bin/bwrap": "absolute unprivileged bubblewrap probe missing",
        "--unshare-user": "probe user namespace boundary missing",
        "--unshare-pid": "probe PID namespace boundary missing",
        "--unshare-ipc": "probe IPC namespace boundary missing",
        "--unshare-uts": "probe UTS namespace boundary missing",
        "--unshare-cgroup-try": "probe cgroup namespace boundary missing",
        "--disable-userns": "nested user namespace denial missing",
        "--die-with-parent": "probe parent lifetime binding missing",
        "--new-session": "probe session isolation missing",
        "--cap-drop ALL": "probe capability drop missing",
        "--ro-bind / /": "probe read-only root missing",
        "--dev /dev": "probe device isolation missing",
        "--proc /proc": "probe proc isolation missing",
        "--tmpfs /dev/shm": "probe shared-memory isolation missing",
        "-- /usr/bin/true >/dev/null 2>&1": "probe fixed diagnostic boundary missing",
    }
    for needle, reason in probe_requirements.items():
        require(probe, needle, reason)
    load_command = '/usr/bin/python3 -I - load "$profile_path" >/dev/null 2>&1'
    require(source, load_command, "restrictive AppArmor profile load missing")
    first_probe = source.find("if ! probe_bubblewrap; then")
    initial_receipt = source.find("initial_sandbox_receipt=")
    current_receipt = source.find("current_sandbox_receipt=")
    profile_load = source.find(load_command)
    second_probe = source.find("if ! probe_bubblewrap; then", first_probe + 1)
    if first_probe < 0 or profile_load < 0 or second_probe < 0:
        raise ContractError("probe and profile-load sequence incomplete")
    if not initial_receipt < first_probe < current_receipt < profile_load < second_probe:
        raise ContractError("probe and profile-load ordering drifted")
    require(source, "loader_status=0", "fixed profile-load status capture missing")
    require(
        source,
        "::error::trusted unprivileged bubblewrap namespace probe failed",
        "fixed namespace-probe diagnostic missing",
    )


def validate(node, actions):
    node_job = node.get("jobs", {}).get("build-test")
    if not isinstance(node_job, dict):
        raise ContractError("node-ci build-test job missing")
    node_steps = node_job.get("steps", [])
    node_provision = named_step(node_steps, PROVISION, "node-ci")
    if node_provision.get("if") != HOSTED_GATE:
        raise ContractError("node-ci provisioner not gated to hosted compatibility execution")
    if node_provision.get("env") != SECRETLESS_ENV:
        raise ContractError("node-ci provisioner credential boundary drifted")
    node_source = node_provision.get("run", "")
    validate_source(node_source)
    provision_index = node_steps.index(node_provision)
    execution_indexes = [
        index
        for index, step in enumerate(node_steps)
        if step.get("name") == NODE_EXECUTION
    ]
    if len(execution_indexes) != 1 or provision_index >= execution_indexes[0]:
        raise ContractError("node-ci provisioning must precede compatibility execution")

    hosted_job = actions.get("jobs", {}).get("hosted-compatibility-tests")
    if not isinstance(hosted_job, dict):
        raise ContractError("actions-ci hosted compatibility job missing")
    if hosted_job.get("runs-on") != "ubuntu-24.04":
        raise ContractError("actions-ci compatibility job not explicitly hosted")
    hosted_steps = hosted_job.get("steps", [])
    hosted_provision = named_step(hosted_steps, PROVISION, "actions-ci")
    if hosted_provision.get("env") != SECRETLESS_ENV:
        raise ContractError("actions-ci provisioner credential boundary drifted")
    if hosted_provision.get("run") != node_source:
        raise ContractError("hosted mirror provisioning drifted")
    hosted_index = hosted_steps.index(hosted_provision)
    execution_indexes = [
        index
        for index, step in enumerate(hosted_steps)
        if step.get("name") == HOSTED_EXECUTION
    ]
    if len(execution_indexes) != 1 or hosted_index >= execution_indexes[0]:
        raise ContractError("actions-ci provisioning must precede compatibility contracts")


def expect_mutation(node, actions, reason, mutate):
    node_mutant = copy.deepcopy(node)
    actions_mutant = copy.deepcopy(actions)
    mutate(node_mutant, actions_mutant)
    try:
        validate(node_mutant, actions_mutant)
    except ContractError as error:
        if str(error) != reason:
            raise AssertionError(
                f"mutation failed for wrong reason: expected {reason!r}, got {str(error)!r}"
            ) from error
        print(f"ok - {reason}")
    else:
        raise AssertionError(f"mutation passed: {reason}")


def provision_step(document, owner):
    if owner == "node":
        steps = document["jobs"]["build-test"]["steps"]
    else:
        steps = document["jobs"]["hosted-compatibility-tests"]["steps"]
    return next(step for step in steps if step.get("name") == PROVISION)


def replace_source(document, owner, old, new):
    step = provision_step(document, owner)
    if old not in step["run"]:
        raise AssertionError(f"mutation source absent: {old}")
    step["run"] = step["run"].replace(old, new, 1)


def replace_mirrored(node, actions, old, new):
    replace_source(node, "node", old, new)
    replace_source(actions, "actions", old, new)


def replace_source_nth(document, owner, old, new, occurrence):
    step = provision_step(document, owner)
    parts = step["run"].split(old)
    if len(parts) <= occurrence:
        raise AssertionError(f"mutation source occurrence absent: {old}")
    step["run"] = old.join(parts[:occurrence]) + new + old.join(parts[occurrence:])


def replace_mirrored_nth(node, actions, old, new, occurrence):
    replace_source_nth(node, "node", old, new, occurrence)
    replace_source_nth(actions, "actions", old, new, occurrence)


node_document = load(ROOT / ".github/workflows/node-ci.yml")
actions_document = load(ROOT / ".github/workflows/actions-ci.yml")
validate(node_document, actions_document)


mutations = [
    ("signed compatibility sandbox package acquisition missing", "apparmor apparmor-profiles bubblewrap", "bubblewrap"),
    ("fixed package-index diagnostic missing", "::error::trusted compatibility sandbox package index acquisition failed", "::error::package index failed for $package_name"),
    ("fixed package-acquisition diagnostic missing", "::error::trusted compatibility sandbox package acquisition failed", "::error::package acquisition failed for $package_name"),
    ("AppArmor package version floor drifted", f"verify_package_floor apparmor '{APPARMOR_FLOOR}'", "verify_package_floor apparmor '0.1.0'"),
    ("AppArmor profiles package version floor drifted", f"verify_package_floor apparmor-profiles '{APPARMOR_FLOOR}'", "verify_package_floor apparmor-profiles '0.1.0'"),
    ("bubblewrap package version floor drifted", "verify_package_floor bubblewrap '0.9.0-1build1'", "verify_package_floor bubblewrap '0.1.0'"),
    ("absolute apt path drifted", "/usr/bin/apt-get", "apt-get"),
    ("absolute package status verification drifted", "/usr/bin/dpkg-query -W", "dpkg-query -W"),
    ("absolute package version verification drifted", "/usr/bin/dpkg --compare-versions", "dpkg --compare-versions"),
    (
        "absolute unprivileged verifier child path drifted",
        '"/usr/bin/python3",\n            "-I",\n            "-c",',
        '"python3",\n            "-I",\n            "-c",',
    ),
    ("absolute Python loader path drifted", '/usr/bin/python3 -I - load "$profile_path"', '/usr/bin/python3 - load "$profile_path"'),
    ("bubblewrap package ownership verification missing", "/usr/bin/dpkg-query -S /usr/bin/bwrap", "/usr/bin/dpkg-query -S /tmp/bwrap"),
    ("AppArmor parser package ownership verification missing", "/usr/bin/dpkg-query -S /sbin/apparmor_parser", "/usr/bin/dpkg-query -S /tmp/apparmor_parser"),
    ("AppArmor profile package ownership verification missing", '/usr/bin/dpkg-query -S "$profile_path"', '/usr/bin/dpkg-query -L "$profile_path"'),
    ("restrictive AppArmor profile path drifted", f"profile_path='{PROFILE_PATH}'", "profile_path='/tmp/bwrap-profile'"),
    ("profile verifier is not bound to package-owned path", "verify_system(sys.argv[2])", f'verify_system("{PROFILE_PATH}")'),
    ("absolute AppArmor parser verifier drifted", 'open_verified_file(\n            "/sbin/apparmor_parser",', 'open_verified_file(\n            "apparmor_parser",'),
    ("absolute bubblewrap verifier drifted", 'read_verified_file(\n            "/usr/bin/bwrap",', 'read_verified_file(\n            "bwrap",'),
    ("symlink rejection missing", "flags |= os.O_NOFOLLOW", "flags |= 0"),
    (
        "regular-file verification missing",
        "not stat.S_ISREG(metadata.st_mode)",
        "False",
    ),
    ("root ownership verification missing", "metadata.st_uid != 0", "False"),
    ("root group verification missing", "metadata.st_gid != 0", "False"),
    ("writable-mode rejection missing", "metadata.st_mode & 0o022", "False"),
    ("executable-mode verification missing", "executable and not metadata.st_mode & 0o111", "executable and False"),
    ("profile executable-mode rejection missing", "not executable and metadata.st_mode & 0o111", "not executable and False"),
    ("set-id mode rejection missing", "or metadata.st_mode & (stat.S_ISUID | stat.S_ISGID)", "or False"),
    ("file capability rejection missing", "or capability_present", "or False"),
    ("capability xattr probe behavior drifted", 'os.getxattr(file_descriptor, "security.capability")', 'b""'),
    ("include-tree symlink rejection missing", "not stat.S_ISDIR(metadata.st_mode)", "False"),
    ("bwrap local profile override rejection missing", '"/etc/apparmor.d/local/bwrap-userns-restrict"', '"/tmp/bwrap-userns-restrict"'),
    ("child local profile override rejection missing", '"/etc/apparmor.d/local/unpriv_bwrap"', '"/tmp/unpriv_bwrap"'),
    ("local profile override symlink rejection missing", "os.lstat(override)", "os.stat(override)"),
    ("AppArmor tunables tree verification missing", 'verify_include_tree("/etc/apparmor.d/tunables", "tunables-tree")', 'verify_include_tree("/tmp/tunables", "tunables-tree")'),
    ("AppArmor ABI include tree verification missing", '"/etc/apparmor.d/abi"', '"/tmp/apparmor-abi"'),
    ("AppArmor include directory ordering missing", "directories.sort()", "pass"),
    ("AppArmor include file ordering missing", "files.sort()", "pass"),
    ("AppArmor include symlink rejection missing", "followlinks=False", "followlinks=True"),
    ("usrmerge parser ancestry verification missing", 'os.lstat("/sbin")', 'os.stat("/sbin")'),
    ("usrmerge parser target verification missing", "or sbin_target not in", "or False and sbin_target not in"),
    ("initial filesystem receipt missing", "initial_sandbox_receipt=", "initial_receipt="),
    ("pre-parse filesystem recheck missing", "current_sandbox_receipt=", "current_receipt="),
    ("filesystem identity binding missing", '"$current_sandbox_receipt" != "$initial_sandbox_receipt"', '"$current_sandbox_receipt" = "$initial_sandbox_receipt"'),
    ("AppArmor ABI semantic guard missing", '"abi <abi/4.0>,"', '"abi <abi/5.0>,"'),
    ("restricted child profile guard missing", "profile unpriv_bwrap flags=", "profile child flags="),
    ("unconfined profile rejection missing", 'r"flags=\\([^)]*\\bunconfined\\b"', 'r"flags=\\([^)]*\\bnot-unconfined\\b"'),
    ("absolute bwrap profile attachment guard missing", "profile bwrap /usr/bin/bwrap flags=", "profile bwrap bwrap flags="),
    ("parent transition is not block-bound", 'if "allow px /** -> bwrap//&unpriv_bwrap," not in parent:', "if False:"),
    ("recursive transition is not child-bound", 'if "allow pix /** -> &unpriv_bwrap," not in child:', "if False:"),
    ("child denial is not block-bound", 'if capability_rules != ["audit deny capability,"]:', "if False:"),
    ("descriptor-bound parser verification missing", "bind_parser=True", "bind_parser=False"),
    ("loader receipt format guard missing", 're.fullmatch(r"[0-9a-f]{64}", expected_receipt)', "expected_receipt"),
    ("loader receipt comparison missing", "receipt != expected_receipt", "False"),
    ("loader expected receipt binding missing", 'EXPECTED_SANDBOX_RECEIPT="$initial_sandbox_receipt"', 'EXPECTED_SANDBOX_RECEIPT="0"'),
    ("loader static profile path binding missing", 'sys.argv[2] != "/usr/share/apparmor/extra-profiles/bwrap-userns-restrict"', "False"),
    ("profile descriptor inheritance missing", "os.set_inheritable(profile_descriptor, True)", "os.close(profile_descriptor)"),
    ("parser descriptor inheritance missing", "os.set_inheritable(parser_descriptor, True)", "os.close(parser_descriptor)"),
    ("parser descriptor execution missing", "os.execve(\n            parser_descriptor,", "os.execve(\n            '/sbin/apparmor_parser',"),
    ("profile descriptor execution path missing", 'f"/proc/self/fd/{profile_descriptor}"', 'sys.argv[2]'),
    (
        "isolated root supervisor Python boundary missing",
        '/usr/bin/python3 -I -c "$supervisor_source"',
        'python3 -I -c "$supervisor_source"',
    ),
    ("probe capability drop missing", "--cap-drop ALL", "--cap-add ALL"),
    (
        "trusted verifier source pipe missing",
        "{ sandbox_verifier_source 2>&1 |",
        "{ sandbox_verifier_source |",
    ),
    (
        "root verifier supervisor source missing",
        "sandbox_supervisor_source() {",
        "sandbox_supervisor() {",
    ),
        (
            "verifier source digest binding missing",
            "hashlib.sha256(verifier_source).hexdigest() != expected_digest",
            "False",
        ),
        (
            "verifier source digest binding drifted",
            "ba649728453d0971df08421476a724ac56dcfc21a95aaa34f1a582da484265ec",
            "0" * 64,
        ),
        ("root supervisor privilege boundary missing", "os.geteuid() != 0", "False"),
    (
        "root supervisor source bound missing",
        "sys.stdin.buffer.read(1048577)",
        "sys.stdin.buffer.read()",
    ),
    (
        "verifier static source decoding missing",
        'verifier_source.decode("utf-8", "strict")',
        'verifier_source.decode("utf-8", "ignore")',
    ),
    (
        "verifier immutable argv and in-memory output boundary missing",
        "stdin=subprocess.DEVNULL,\n        stdout=subprocess.PIPE,\n        stderr=subprocess.STDOUT,",
        "stdin=subprocess.PIPE,\n        stdout=subprocess.PIPE,\n        stderr=subprocess.STDOUT,",
    ),
    ("verifier fixed working directory missing", 'cwd="/"', 'cwd="/tmp"'),
    ("verifier execution bound missing", "timeout=60", "timeout=None"),
    (
        "verifier explicit status capture missing",
        "timeout=60,\n        check=False,",
        "timeout=60,\n        check=True,",
    ),
    ("verifier descriptor isolation missing", "close_fds=True", "close_fds=False"),
    ("verifier process isolation missing", "start_new_session=True", "start_new_session=False"),
    (
        "verifier child fixed environment missing",
        '"HOME": "/nonexistent",',
        '"HOME": "/tmp",',
    ),
    (
        "supervisor exact receipt status binding missing",
        'status == 0 and re.fullmatch(rb"[0-9a-f]{64}\\n", output)',
        're.fullmatch(rb"[0-9a-f]{64}\\n", output)',
    ),
    (
        "supervisor exact diagnostic status binding missing",
        "status == 1 and output in diagnostic_status",
        "output in diagnostic_status",
    ),
    (
        "supervisor diagnostic phase mapping missing",
        "status = diagnostic_status[output]",
        "status = 81",
    ),
    (
        "isolated root supervisor Python boundary missing",
        '/usr/bin/python3 -I -c "$supervisor_source"',
        '/usr/bin/python3 -c "$supervisor_source"',
    ),
    (
        "sanitized supervisor receipt filter missing",
        '[[ "$supervisor_output" =~ ^[0-9a-f]{64}$ ]]',
        '[[ -n "$supervisor_output" ]]',
    ),
    (
        "sanitized supervisor diagnostic filter missing",
        '"$supervisor_output" = "::error::trusted compatibility sandbox filesystem boundary unsafe phase=$supervisor_phase"',
        '-n "$supervisor_output"',
    ),
    ("verifier unknown diagnostic fallback missing", "echo '::error::trusted compatibility sandbox filesystem boundary unsafe phase=unknown' >&2", 'printf "%s\\n" "$1" >&2'),
    ("pre-load receipt mismatch diagnostic drifted", 'echo "::error::trusted compatibility sandbox filesystem boundary unsafe phase=receipt-recomputation" >&2', 'echo "::error::trusted compatibility sandbox filesystem boundary changed" >&2'),
    (
        "signed apt index update command drifted",
        "update >/dev/null 2>&1",
        "update >/dev/null",
    ),
    ("loader raw stderr suppression missing", '/usr/bin/python3 -I - load "$profile_path" >/dev/null 2>&1 || loader_status=$?', '/usr/bin/python3 -I - load "$profile_path" >/dev/null || loader_status=$?'),
]
for reason, old, new in mutations:
    expect_mutation(
        node_document,
        actions_document,
        reason,
        lambda node, actions, old=old, new=new: replace_mirrored(node, actions, old, new),
    )

for phase in BOUNDARY_PHASES:
    expect_mutation(
        node_document,
        actions_document,
        f"boundary phase allowlist drifted: {phase}",
        lambda node, actions, phase=phase: replace_mirrored(
            node,
            actions,
            f'"{phase}"',
            f'"mutated-{phase}"',
        ),
    )

loader_phase_markers = {
    "ancestor-directories": "70) loader_phase='ancestor-directories' ;;",
    "usrmerge-parser-link": "71) loader_phase='usrmerge-parser-link' ;;",
    "local-overrides": "72) loader_phase='local-overrides' ;;",
    "abi-tree": "73) loader_phase='abi-tree' ;;",
    "tunables-tree": "74) loader_phase='tunables-tree' ;;",
    "bwrap-binary": "75) loader_phase='bwrap-binary' ;;",
    "parser-binary": "76) loader_phase='parser-binary' ;;",
    "package-profile": "77) loader_phase='package-profile' ;;",
    "profile-semantics": "78) loader_phase='profile-semantics' ;;",
    "receipt-recomputation": "79) loader_phase='receipt-recomputation' ;;",
    "profile-load": "1|80) loader_phase='profile-load' ;;",
    "unknown": "81) loader_phase='unknown' ;;",
}
for phase, marker in loader_phase_markers.items():
    expect_mutation(
        node_document,
        actions_document,
        f"loader phase mapping missing for {phase}",
        lambda node, actions, marker=marker: replace_mirrored(
            node,
            actions,
            marker,
            marker.replace(f"'{phase}'", "'mutated-phase'"),
        ),
    )

expect_mutation(
    node_document,
    actions_document,
    "loader unknown status fallback missing",
    lambda node, actions: replace_mirrored(
        node,
        actions,
        "*) loader_phase='unknown' ;;",
        "82) loader_phase='unknown' ;;",
    ),
)

expect_mutation(
    node_document,
    actions_document,
    "unknown boundary fallback drifted",
    lambda node, actions: replace_mirrored(
        node,
        actions,
        'return "unknown"',
        "return str(error)",
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "boundary diagnostic drifted for ancestor-directories",
    lambda node, actions: replace_mirrored(
        node,
        actions,
        'f"phase={boundary_phase(error)}"',
        'f"phase={boundary_phase(error)} detail={error}"',
    ),
)

for reason, old in (
    ("include-tree root ownership verification missing", "metadata.st_uid != 0"),
    ("include-tree writable-mode rejection missing", "metadata.st_mode & 0o022"),
):
    expect_mutation(
        node_document,
        actions_document,
        reason,
        lambda node, actions, old=old: replace_mirrored_nth(node, actions, old, "False", 2),
    )

expect_mutation(
    node_document,
    actions_document,
    "privileged bubblewrap probe forbidden",
    lambda node, actions: replace_mirrored_nth(
        node,
        actions,
            "/usr/bin/env -i \\\n    PATH=",
            "/usr/bin/sudo --non-interactive /usr/bin/env -i \\\n    PATH=",
            1,
        ),
)
expect_mutation(
    node_document,
    actions_document,
    "system-wide userns override forbidden",
    lambda node, actions: replace_mirrored(
        node,
        actions,
        "set -euo pipefail",
        "set -euo pipefail\n/usr/bin/sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0",
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "setuid fallback forbidden",
    lambda node, actions: replace_mirrored(node, actions, "set -euo pipefail", "set -euo pipefail\nchmod u+s /usr/bin/bwrap"),
)


def move_load_before_probe(node, actions):
    load_command = (
        '/usr/bin/python3 -I - load "$profile_path" >/dev/null 2>&1 || loader_status=$?'
    )
    recheck = 'current_sandbox_receipt="$(verify_sandbox_files)" || exit 1'
    for document, owner in ((node, "node"), (actions, "actions")):
        step = provision_step(document, owner)
        source = step["run"].replace(recheck, "", 1)
        step["run"] = source.replace(load_command, f"{load_command}\n{recheck}", 1)


expect_mutation(
    node_document,
    actions_document,
    "probe and profile-load ordering drifted",
    move_load_before_probe,
)
expect_mutation(
    node_document,
    actions_document,
    "probe and profile-load sequence incomplete",
    lambda node, actions: replace_mirrored(
        node,
        actions,
        "if ! probe_bubblewrap; then",
        "if false; then",
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "node-ci provisioner not gated to hosted compatibility execution",
    lambda node, _actions: provision_step(node, "node").__setitem__("if", "runner.environment == 'self-hosted'"),
)
expect_mutation(
    node_document,
    actions_document,
    "hosted mirror provisioning drifted",
    lambda _node, actions: replace_source(
        actions,
        "actions",
        "EXPECTED_SANDBOX_RECEIPT=",
        "DRIFTED_SANDBOX_RECEIPT=",
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "actions-ci hosted compatibility job missing",
    lambda _node, actions: actions["jobs"].pop("hosted-compatibility-tests"),
)
expect_mutation(
    node_document,
    actions_document,
    "node-ci build-test job missing",
    lambda node, _actions: node["jobs"].pop("build-test"),
)
expect_mutation(
    node_document,
    actions_document,
    "node-ci provisioner missing",
    lambda node, _actions: node["jobs"]["build-test"].__setitem__("steps", [step for step in node["jobs"]["build-test"]["steps"] if step.get("name") != PROVISION]),
)
expect_mutation(
    node_document,
    actions_document,
    "actions-ci provisioner missing",
    lambda _node, actions: actions["jobs"]["hosted-compatibility-tests"].__setitem__("steps", [step for step in actions["jobs"]["hosted-compatibility-tests"]["steps"] if step.get("name") != PROVISION]),
)


def move_node_provisioner(node, _actions):
    steps = node["jobs"]["build-test"]["steps"]
    provision = provision_step(node, "node")
    steps.remove(provision)
    execution = next(index for index, step in enumerate(steps) if step.get("name") == NODE_EXECUTION)
    steps.insert(execution + 1, provision)


expect_mutation(node_document, actions_document, "node-ci provisioning must precede compatibility execution", move_node_provisioner)


def move_hosted_provisioner(_node, actions):
    steps = actions["jobs"]["hosted-compatibility-tests"]["steps"]
    provision = provision_step(actions, "actions")
    steps.remove(provision)
    execution = next(index for index, step in enumerate(steps) if step.get("name") == HOSTED_EXECUTION)
    steps.insert(execution + 1, provision)


expect_mutation(actions=actions_document, node=node_document, reason="actions-ci provisioning must precede compatibility contracts", mutate=move_hosted_provisioner)

print("ok - hosted restrictive AppArmor and unprivileged bubblewrap provisioning")
