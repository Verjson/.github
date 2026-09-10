#!/usr/bin/env python3
import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "scripts/app-key-bootstrap-contract.json"
REPOSITORY = "Verjson/.github"
REPOSITORY_ID = 1269388380
SEAL_WORKFLOW = ".github/workflows/app-key-bootstrap.yml"
VERIFY_WORKFLOW = ".github/workflows/app-key-bootstrap-verify.yml"
SOURCE_FILES = (SEAL_WORKFLOW, VERIFY_WORKFLOW, "scripts/app-key-bootstrap.py",
                "scripts/app-key-bootstrap-contract.json", "scripts/app-key-bootstrap-requirements.txt")
ROLES = {"release": "RELEASE_APP_PRIVATE_KEY", "merge": "MERGE_APP_PRIVATE_KEY", "review": "AI_REVIEW_APP_PRIVATE_KEY"}
MAX_ARTIFACT_BYTES = 65_536


class BootstrapError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise BootstrapError(message)


def strict_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate JSON field")
            result[key] = value
        return result
    try:
        return json.loads(raw, object_pairs_hook=pairs, parse_constant=lambda _: require(False, "invalid JSON constant"))
    except (ValueError, UnicodeError) as error:
        raise BootstrapError("invalid JSON") from error


def digest(value):
    return "sha256:" + hashlib.sha256(value).hexdigest()


def same_json(left, right):
    return json.dumps(left, sort_keys=True, allow_nan=False) == json.dumps(right, sort_keys=True, allow_nan=False)


def contract_digest(contract):
    return digest(json.dumps(contract, sort_keys=True, separators=(",", ":")).encode())


def load_contract():
    contract = strict_json(CONTRACT.read_bytes())
    require(contract.get("schema") == 1 and contract.get("repository") == {
        "name": REPOSITORY, "id": REPOSITORY_ID,
    }, "bootstrap is scoped only to the reviewed repository")
    require(set(contract.get("roles", {})) == set(ROLES), "role set differs")
    for role, secret in ROLES.items():
        target = contract["roles"][role]
        require(target.get("secret") == secret, "role secret mapping differs")
        require(len(base64.b64decode(target["public_key"]["key"], validate=True)) == 32,
                "invalid reviewed encryption key")
    return contract


def encrypt(value, key):
    from nacl.public import PublicKey, SealedBox
    return base64.b64encode(SealedBox(PublicKey(base64.b64decode(key, validate=True))).encrypt(value)).decode("ascii")


def seal(contract, environment, encrypt_value=encrypt):
    require(environment.get("GITHUB_REPOSITORY") == REPOSITORY
            and environment.get("GITHUB_REPOSITORY_ID") == str(REPOSITORY_ID)
            and environment.get("GITHUB_REF") == "refs/heads/main"
            and environment.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and environment.get("GITHUB_RUN_ATTEMPT") == "1"
            and environment.get("GITHUB_WORKFLOW_REF") == f"{REPOSITORY}/{SEAL_WORKFLOW}@refs/heads/main",
            "only a first-attempt protected-main bootstrap may seal keys")
    sha = environment.get("GITHUB_SHA", "")
    run_id = environment.get("GITHUB_RUN_ID", "")
    require(re.fullmatch(r"[0-9a-f]{40}", sha) and re.fullmatch(r"[1-9][0-9]*", run_id), "invalid run identity")
    result = {"schema": 1, "repository_id": REPOSITORY_ID, "workflow": SEAL_WORKFLOW,
              "source_sha": sha, "run_id": int(run_id), "run_attempt": 1,
              "contract_digest": contract_digest(contract), "roles": {}}
    for role, target in contract["roles"].items():
        value = environment.pop(target["secret"], "")
        require(isinstance(value, str) and 100 <= len(value.encode()) <= 16_384, f"{role} source key is absent or malformed")
        ciphertext = encrypt_value(value.encode(), target["public_key"]["key"])
        result["roles"][role] = {"destination": target, "encrypted_value": ciphertext}
    return result


class GitHub:
    def request(self, path, method="GET", body=None, binary=False):
        command = ["gh", "api", "--hostname", "github.com", "--method", method, path]
        if body is not None:
            command += ["--input", "-"]
        try:
            result = subprocess.run(command, input=json.dumps(body).encode() if body is not None else None,
                                    capture_output=True, timeout=60, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise BootstrapError("GitHub request could not be completed") from error
        require(result.returncode == 0, f"GitHub {method} failed for {path}")
        if binary:
            return result.stdout
        return strict_json(result.stdout) if result.stdout else {}


def validate_source(api, sha):
    require(re.fullmatch(r"[0-9a-f]{40}", sha), "source SHA must be immutable")
    repository = api.request(f"repos/{REPOSITORY}")
    require(repository.get("id") == REPOSITORY_ID and repository.get("default_branch") == "main", "repository identity differs")
    branch = api.request(f"repos/{REPOSITORY}/branches/main")
    require(branch.get("protected") is True, "main is not protected")
    comparison = api.request(f"repos/{REPOSITORY}/compare/{sha}...{branch['commit']['sha']}")
    require(comparison.get("status") in ("ahead", "identical") and comparison.get("behind_by") == 0,
            "reviewed source is not on protected main")
    for path in SOURCE_FILES:
        remote = api.request(f"repos/{REPOSITORY}/contents/{path}?ref={sha}")
        require(base64.b64decode(remote["content"]) == (ROOT / path).read_bytes(), "local bootstrap source differs from reviewed commit")


def validate_run(api, sha, run_id, workflow, now=None):
    run = api.request(f"repos/{REPOSITORY}/actions/runs/{run_id}")
    registration = api.request(f"repos/{REPOSITORY}/actions/workflows/{workflow.rsplit('/', 1)[1]}")
    require(run.get("id") == run_id and run.get("event") == "workflow_dispatch"
            and run.get("run_attempt") == 1 and run.get("head_sha") == sha
            and run.get("head_branch") == "main" and run.get("path") == workflow
            and run.get("repository", {}).get("id") == REPOSITORY_ID
            and run.get("head_repository", {}).get("id") == REPOSITORY_ID
            and run.get("workflow_id") == registration.get("id")
            and registration.get("path") == workflow and registration.get("state") == "active"
            and run.get("status") == "completed" and run.get("conclusion") == "success", "workflow origin or result differs")
    created = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
    require(created.tzinfo is not None and timedelta(0) <= (now or datetime.now(timezone.utc)) - created <= timedelta(days=1), "workflow receipt is stale")
    return run


def validate_environment(api, target):
    prefix = f"repos/{REPOSITORY}/environments/{target['environment']}"
    environment = api.request(prefix)
    require(environment.get("id") == target["environment_id"] and environment.get("name") == target["environment"], "environment identity differs")
    require(environment.get("deployment_branch_policy") == {"protected_branches": False, "custom_branch_policies": True}, "environment is not main-only")
    rules = environment.get("protection_rules", [])
    require(len(rules) == 1 and rules[0].get("type") == "branch_policy" and rules[0].get("id") == target["protection_rule_id"], "environment protection rule differs")
    policies = api.request(prefix + "/deployment-branch-policies")
    require(policies.get("total_count") == 1 and len(policies.get("branch_policies", [])) == 1, "environment branch policy count differs")
    policy = policies["branch_policies"][0]
    require({key: policy.get(key) for key in ("id", "name", "type")} == {"id": target["branch_policy_id"], "name": "main", "type": "branch"}, "environment branch destination differs")
    require(api.request(prefix + "/secrets/public-key") == target["public_key"], "environment encryption key changed")
    return prefix


def download_ciphertext(api, contract, sha, run_id):
    listing = api.request(f"repos/{REPOSITORY}/actions/runs/{run_id}/artifacts")
    require(listing.get("total_count") == 1 and len(listing.get("artifacts", [])) == 1, "bootstrap must publish exactly one artifact")
    artifact = listing["artifacts"][0]
    require(type(artifact.get("id")) is int and artifact["id"] > 0
            and artifact.get("name") == f"app-key-bootstrap-{run_id}-1"
            and artifact.get("expired") is False
            and type(artifact.get("size_in_bytes")) is int and 0 < artifact["size_in_bytes"] <= MAX_ARTIFACT_BYTES,
            "ciphertext artifact identity or size differs")
    origin = artifact.get("workflow_run", {})
    require(origin.get("id") == run_id and origin.get("repository_id") == REPOSITORY_ID
            and origin.get("head_repository_id") == REPOSITORY_ID and origin.get("head_sha") == sha
            and origin.get("head_branch") == "main", "artifact origin differs")
    archive = api.request(f"repos/{REPOSITORY}/actions/artifacts/{artifact['id']}/zip", binary=True)
    require(len(archive) <= MAX_ARTIFACT_BYTES and digest(archive) == artifact.get("digest"), "artifact digest or size differs")
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        require(zipped.namelist() == ["sealed-keys.json"] and zipped.getinfo("sealed-keys.json").file_size <= MAX_ARTIFACT_BYTES,
                "artifact contains unexpected files")
        document = strict_json(zipped.read("sealed-keys.json"))
    expected = {"schema": 1, "repository_id": REPOSITORY_ID, "workflow": SEAL_WORKFLOW,
                "source_sha": sha, "run_id": run_id, "run_attempt": 1, "contract_digest": contract_digest(contract)}
    require(set(document) == set(expected) | {"roles"}
            and all(same_json(document.get(key), value) for key, value in expected.items())
            and set(document.get("roles", {})) == set(ROLES), "sealed document binding differs")
    for role, target in contract["roles"].items():
        entry = document["roles"][role]
        require(set(entry) == {"destination", "encrypted_value"} and same_json(entry["destination"], target), "sealed destination differs")
        value = base64.b64decode(entry["encrypted_value"], validate=True)
        require(148 <= len(value) <= 16_432, "sealed value is malformed")
    return document, {"artifact_id": artifact["id"], "artifact_digest": artifact["digest"]}


def write_receipt(path, receipt):
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(json.dumps(receipt, indent=2) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def require_absent(api, prefix, target):
    listing = api.request(prefix + "/secrets")
    require(type(listing.get("total_count")) is int
            and listing["total_count"] == len(listing.get("secrets", []))
            and all(secret.get("name") != target["secret"] for secret in listing.get("secrets", [])),
            "destination secret already exists; automatic overwrite is forbidden")


def apply(api, contract, sha, run_id, roles, receipt_path):
    require(not receipt_path.exists(), "receipt already exists; inspect it before any retry")
    validate_source(api, sha)
    validate_run(api, sha, run_id, SEAL_WORKFLOW)
    document, artifact = download_ciphertext(api, contract, sha, run_id)
    for target in contract["roles"].values():
        validate_environment(api, target)
    receipt = {"schema": 1, "repository": REPOSITORY, "source_sha": sha, "run_id": run_id,
               **artifact, "roles": {}}
    for role in roles:
        target = contract["roles"][role]
        require_absent(api, f"repos/{REPOSITORY}/environments/{target['environment']}", target)
    with receipt_path.open("x") as stream:
        stream.write(json.dumps(receipt) + "\n")
    for role in roles:
        target = contract["roles"][role]
        prefix = validate_environment(api, target)
        require_absent(api, prefix, target)
        receipt["roles"][role] = {"state": "uncertain", "environment_id": target["environment_id"]}
        write_receipt(receipt_path, receipt)
        api.request(prefix + f"/secrets/{target['secret']}", "PUT", {
            "encrypted_value": document["roles"][role]["encrypted_value"], "key_id": target["public_key"]["key_id"],
        })
        secret = api.request(prefix + f"/secrets/{target['secret']}")
        require(secret.get("name") == target["secret"] and isinstance(secret.get("updated_at"), str), "provisioning metadata is unavailable")
        receipt["roles"][role].update(state="created", updated_at=secret["updated_at"])
        write_receipt(receipt_path, receipt)
    return receipt


def verify_scope(contract, role, environment, repositories):
    target = contract["roles"][role]
    require(environment.get("MINTED_APP_SLUG") == target["app_slug"]
            and environment.get("MINTED_INSTALLATION_ID") == str(target["installation_id"]), "minted App identity differs")
    require(repositories.get("total_count") == 1 and len(repositories.get("repositories", [])) == 1
            and repositories["repositories"][0].get("id") == REPOSITORY_ID
            and repositories["repositories"][0].get("full_name") == REPOSITORY, "minted token repository scope differs")


def verify_receipt(api, contract, sha, run_id, paths):
    validate_source(api, sha)
    run = validate_run(api, sha, run_id, VERIFY_WORKFLOW)
    covered = {}
    for path in paths:
        receipt = strict_json(path.read_bytes())
        require(receipt.get("source_sha") == sha and receipt.get("repository") == REPOSITORY, "provisioning receipt source differs")
        for role, value in receipt.get("roles", {}).items():
            require(role in ROLES and role not in covered and value.get("state") == "created", "provisioning is incomplete or duplicated")
            covered[role] = value
    require(set(covered) == set(ROLES), "provisioning receipts do not cover all roles")
    started = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
    for role, target in contract["roles"].items():
        updated = datetime.fromisoformat(covered[role]["updated_at"].replace("Z", "+00:00"))
        require(updated.tzinfo is not None and started > updated, "verification must start after every environment key was provisioned")
        prefix = validate_environment(api, target)
        secret = api.request(prefix + f"/secrets/{target['secret']}")
        require(covered[role].get("environment_id") == target["environment_id"]
                and secret.get("name") == target["secret"] and secret.get("updated_at") == covered[role].get("updated_at"), "environment secret changed after provisioning")
    jobs = api.request(f"repos/{REPOSITORY}/actions/runs/{run_id}/attempts/1/jobs")
    require(jobs.get("total_count") == 3 and len(jobs.get("jobs", [])) == 3
            and {job.get("name") for job in jobs["jobs"]} == {f"verify-{role}" for role in ROLES}
            and all(job.get("conclusion") == "success" for job in jobs["jobs"]), "App identity verification jobs did not all pass")


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    sealing = commands.add_parser("seal")
    sealing.add_argument("--output", type=Path, required=True)
    applying = commands.add_parser("apply")
    checking = commands.add_parser("verify")
    for child in (applying, checking):
        child.add_argument("--source-sha", required=True)
        child.add_argument("--run-id", type=int, required=True)
    applying.add_argument("--role", choices=ROLES, action="append")
    applying.add_argument("--receipt", type=Path, required=True)
    checking.add_argument("--receipt", type=Path, action="append", required=True)
    scope = commands.add_parser("verify-scope")
    scope.add_argument("--role", choices=ROLES, required=True)
    args = parser.parse_args()
    try:
        contract = load_contract()
        if args.command == "seal":
            document = seal(contract, os.environ)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(document, sort_keys=True) + "\n")
        elif args.command == "apply":
            roles = args.role or list(ROLES)
            require(len(set(roles)) == len(roles), "duplicate requested role")
            apply(GitHub(), contract, args.source_sha, args.run_id, roles, args.receipt)
            print("Provisioned selected environment keys; retain receipt and run App verification.")
        elif args.command == "verify-scope":
            verify_scope(contract, args.role, os.environ, GitHub().request("installation/repositories"))
            print(f"Verified {args.role} App identity and .github-only token scope.")
        else:
            verify_receipt(GitHub(), contract, args.source_sha, args.run_id, args.receipt)
            print("All three environment App identities and repository scopes verified.")
    except (BootstrapError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile):
        print("App key bootstrap failed closed; inspect metadata receipts before retrying. No secret diagnostics are emitted.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
