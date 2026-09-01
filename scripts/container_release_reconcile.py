#!/usr/bin/env python3
"""Fail-closed pre-credential release-tree reconciliation."""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path


HOOK = "scripts/release-reconcile.sh"
MAX_ALLOWLIST = 32
PATH_PATTERN = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._/-]*$")
# Surfaces the release engine itself owns, or that decide what code runs with the
# release App token. Reconciliation may never be pointed at any of them.
PROTECTED_ROOTS = frozenset({"RELEASES", "CHANGELOG", "NEXT"})
PROTECTED_FILES = frozenset({
    HOOK,
    "scripts/container_release_promotion.py",
    "scripts/container_release_manifest.py",
    "scripts/container_artifact_extract.py",
    "scripts/container_attestation_verify.py",
    "scripts/container_release_reconcile.py",
    "scripts/container-release-contract.test.sh",
})


class ReconcileError(Exception):
    pass


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise ReconcileError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def tracked_mode(root: Path, path: str) -> str:
    record = git(root, "ls-files", "--stage", "-z", "--", path).split("\0")[0]
    return record.split()[0] if record else ""


def validate_allowlist(root: Path, raw: str) -> list:
    try:
        allowlist = json.loads(raw)
    except ValueError as error:
        raise ReconcileError(f"reconciliation allowlist is not valid JSON: {error}") from None
    if not isinstance(allowlist, list) or not allowlist:
        raise ReconcileError("reconciliation allowlist must be a non-empty JSON array")
    if len(allowlist) > MAX_ALLOWLIST:
        raise ReconcileError(f"reconciliation allowlist exceeds {MAX_ALLOWLIST} reviewed paths")
    if len(set(allowlist)) != len(allowlist):
        raise ReconcileError("reconciliation allowlist contains duplicate paths")
    for path in allowlist:
        if not isinstance(path, str) or not PATH_PATTERN.fullmatch(path):
            raise ReconcileError(f"reconciliation allowlist entry is not a normalized repository-relative path: {path!r}")
        segments = path.split("/")
        if any(segment in ("", ".", "..") or segment.startswith(".git") for segment in segments):
            raise ReconcileError(f"reconciliation allowlist entry is not a normalized repository-relative path: {path!r}")
        if segments[0] in PROTECTED_ROOTS or path in PROTECTED_FILES:
            raise ReconcileError(f"reconciliation allowlist may not name a release-engine surface: {path}")
        mode = tracked_mode(root, path)
        if mode == "":
            raise ReconcileError(f"reconciliation allowlist entry is not a reviewed tracked file: {path}")
        if mode not in BLOB_MODES:
            raise ReconcileError(f"reconciliation allowlist entry {path} is a symlink or submodule, not a reviewed regular file")
    return allowlist


def require_bounded_manifest(root: Path, manifest: str) -> None:
    if not PATH_PATTERN.fullmatch(manifest) or any(
        segment in ("", ".", "..") for segment in manifest.split("/")
    ):
        raise ReconcileError(f"release manifest path is not repository-relative: {manifest!r}")
    path = root / manifest
    if path.is_symlink() or not path.is_file():
        raise ReconcileError(f"release manifest {manifest} is absent or not a regular file")


def require_pinned_contract(root: Path, contract_root: str, contract_ref: str, stage: str) -> None:
    """The pinned engine checkout decides what runs with the release App token."""
    contract = root / contract_root
    if contract.is_symlink() or not contract.is_dir():
        raise ReconcileError(f"pinned contract checkout {contract_root} is absent or not a directory")
    if git(contract, "rev-parse", "HEAD").strip() != contract_ref:
        raise ReconcileError(f"pinned contract checkout is not at the bound contract ref ({stage})")
    if git(contract, "status", "--porcelain", "--untracked-files=all").strip():
        raise ReconcileError(f"pinned contract checkout was modified ({stage})")


def require_reviewed_hook(root: Path) -> None:
    tracked = git(root, "ls-files", "--", HOOK).splitlines()
    if HOOK not in tracked:
        raise ReconcileError(f"{HOOK} is not tracked in the reviewed release tree")
    if git(root, "ls-files", "--stage", "--", HOOK).split()[0] == "120000":
        raise ReconcileError(f"{HOOK} is a symlink; the hook must be a reviewed regular file")
    path = root / HOOK
    if path.is_symlink() or not path.is_file():
        raise ReconcileError(f"{HOOK} is a symlink or not a regular file")
    if not os.access(path, os.X_OK):
        raise ReconcileError(f"{HOOK} is not executable")


def require_clean_tracked_tree(root: Path) -> None:
    dirty = [
        path for staged, worktree, path in status_entries(root)
        if not (staged == "?" and worktree == "?")
    ]
    if dirty:
        raise ReconcileError(
            "the tracked release tree is not clean before reconciliation: " + ", ".join(sorted(dirty))
        )


def run_hook(root: Path, version: str, manifest: str, timeout: int) -> None:
    """Run the reviewed hook with an allowlisted environment in its own process group.

    The environment is built from scratch rather than filtered: a denylist cannot
    keep up with new credential-bearing variables, and this hook runs while the
    job is one step away from minting the release App token.
    """
    environment = {
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", str(root)),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "RELEASE_VERSION": version,
        "RELEASE_MANIFEST": manifest,
    }
    with open(os.devnull, "rb") as stdin:
        process = subprocess.Popen(
            [f"./{HOOK}", version, manifest],
            cwd=str(root), env=environment, stdin=stdin, start_new_session=True,
        )
        # Resolve the group while the leader is alive: after `wait()` reaps it the
        # pid is gone, but the group can still hold processes the hook backgrounded.
        group = os.getpgid(process.pid)
        try:
            returncode = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            terminate_group(process, group)
            raise ReconcileError(f"{HOOK} timed out after {timeout}s") from None
        finally:
            # Anything the hook backgrounded must not outlive this bounded step and
            # observe the release App token that is minted immediately afterwards.
            terminate_group(process, group)
    if returncode != 0:
        raise ReconcileError(f"{HOOK} exited {returncode}")


def terminate_group(process: subprocess.Popen, group: int) -> None:
    try:
        os.killpg(group, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    process.wait()


BLOB_MODES = {"100644", "100755"}


def status_entries(root: Path) -> list:
    """Parse `git status --porcelain=v1 -z -uall` into (index, worktree, path) triples."""
    raw = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    fields = raw.split("\0")
    entries = []
    index = 0
    while index < len(fields):
        field = fields[index]
        index += 1
        if not field:
            continue
        code, path = field[:2], field[3:]
        if code[0] in "RC":
            index += 1  # rename and copy records carry a second, original path
        entries.append((code[0], code[1], path))
    return entries


def untracked_paths(root: Path) -> set:
    return {path for staged, worktree, path in status_entries(root) if staged == "?" and worktree == "?"}


def validate_tree(root: Path, allowlist: list, pre_existing_untracked: set) -> list:
    changed = []
    for staged, worktree, path in status_entries(root):
        if staged == "?" and worktree == "?":
            if path not in pre_existing_untracked:
                raise ReconcileError(f"hook produced untracked output: {path}")
            continue
        if staged != " ":
            raise ReconcileError(f"hook staged its own change to the index: {path}")
        if worktree != "M":
            raise ReconcileError(
                f"hook made a non-content change ({worktree!r}) to {path}; "
                "deletion, rename and type changes are rejected"
            )
        if path not in allowlist:
            raise ReconcileError(f"hook changed a path outside the reviewed allowlist: {path}")
        changed.append(path)

    raw = git(root, "diff", "--raw", "-z").split("\0")
    index = 0
    while index < len(raw):
        record = raw[index]
        index += 1
        if not record.startswith(":"):
            continue
        source_mode, destination_mode = record[1:].split(" ")[:2]
        path = raw[index]
        index += 1
        if source_mode != destination_mode or destination_mode not in BLOB_MODES:
            raise ReconcileError(
                f"hook changed the file mode or type of {path} "
                f"({source_mode} -> {destination_mode})"
            )
        if (root / path).is_symlink() or not (root / path).is_file():
            raise ReconcileError(f"reconciled path {path} is not a regular file")
    return sorted(changed)


def content_fingerprint(root: Path, paths: list) -> str:
    """Blob hashes of the reconciled working-tree files.

    `git diff --raw` reports an all-zero destination hash for unstaged worktree
    changes, so it cannot distinguish two different reconciliations of the same
    path; hashing the files themselves can.
    """
    return "" if not paths else git(root, "hash-object", "--", *paths)


def rollback(root: Path, pre_existing_untracked: set) -> None:
    try:
        git(root, "reset", "-q")
        git(root, "checkout", "--", ".")
        for path in untracked_paths(root) - pre_existing_untracked:
            candidate = root / path
            if candidate.is_symlink() or candidate.is_file():
                candidate.unlink()
    except (OSError, ReconcileError) as error:
        print(f"release reconciliation rollback incomplete: {error}", file=sys.stderr)


def reconcile(root: Path, args) -> list:
    allowlist = validate_allowlist(root, args.allowlist)
    require_bounded_manifest(root, args.manifest)
    require_pinned_contract(root, args.contract_root, args.contract_ref, "before reconciliation")
    require_reviewed_hook(root)
    require_clean_tracked_tree(root)
    pre_existing_untracked = untracked_paths(root)
    try:
        run_hook(root, args.version, args.manifest, args.timeout)
        changed = validate_tree(root, allowlist, pre_existing_untracked)
        first = content_fingerprint(root, changed)
        # Releases are retried. Re-run the hook against its own output and require
        # a fixed point, so a retry can never produce a different release tree.
        run_hook(root, args.version, args.manifest, args.timeout)
        if validate_tree(root, allowlist, pre_existing_untracked) != changed \
                or content_fingerprint(root, changed) != first:
            raise ReconcileError(f"{HOOK} is not idempotent: a second run changed the release tree")
        require_pinned_contract(root, args.contract_root, args.contract_ref, "after reconciliation")
    except BaseException:
        rollback(root, pre_existing_untracked)
        raise
    if changed:
        git(root, "add", "--", *changed)
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--allowlist", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--contract-root", required=True)
    parser.add_argument("--contract-ref", required=True)
    parser.add_argument("--timeout", required=True, type=int)
    parser.add_argument("--staged-list", required=True)
    args = parser.parse_args()
    root = args.repo_root.resolve()
    try:
        staged = reconcile(root, args)
        (root / args.staged_list).write_text(
            "".join(f"{path}\n" for path in staged), encoding="utf-8",
        )
    except (OSError, ValueError, ReconcileError, subprocess.TimeoutExpired) as error:
        print(f"release reconciliation rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
