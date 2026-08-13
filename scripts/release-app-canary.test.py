"""Semantic and mutation contract for the protected release App canary."""

from __future__ import annotations

import copy
import pathlib
import re
import sys

import yaml


ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/release-app-canary.yml"
TOKEN_ACTION = (
    "actions/create-github-app-token@"
    "bcd2ba49218906704ab6c1aa796996da409d3eb1"
)
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"


def triggers(document: dict) -> object:
    return document.get("on", document.get(True))


def validate(document: dict, raw: str) -> list[str]:
    problems: list[str] = []
    trigger = triggers(document)
    if not isinstance(trigger, dict) or set(trigger) != {"workflow_dispatch"}:
        problems.append("canary is not manual-only")
    elif trigger["workflow_dispatch"] not in (None, {}):
        problems.append("workflow_dispatch exposes user-controlled inputs")
    if document.get("permissions") != {"contents": "read"}:
        problems.append("workflow GITHUB_TOKEN is not contents-read-only")

    job = (document.get("jobs") or {}).get("canary") or {}
    if job.get("runs-on") != "ubuntu-24.04":
        problems.append("canary does not use the fixed GitHub-hosted runner")
    if job.get("permissions") != {"contents": "read"}:
        problems.append("job GITHUB_TOKEN is not contents-read-only")
    steps = job.get("steps") or []
    by_id = {step.get("id"): step for step in steps if step.get("id")}
    mint = by_id.get("release-app-token") or {}
    push = by_id.get("push") or {}
    checkout = next(
        (step for step in steps if str(step.get("uses", "")).startswith("actions/checkout@")),
        {},
    )
    if checkout.get("uses") != CHECKOUT_ACTION:
        problems.append("checkout pin changed")
    checkout_with = checkout.get("with") or {}
    if checkout_with.get("ref") != "${{ github.sha }}" or checkout_with.get("persist-credentials") is not False:
        problems.append("checkout is not bound to the executing revision without credentials")
    if mint.get("uses") != TOKEN_ACTION:
        problems.append("token action pin changed")
    expected_mint = {
        "client-id": "${{ vars.RELEASE_APP_CLIENT_ID }}",
        "private-key": "${{ secrets.RELEASE_APP_PRIVATE_KEY }}",
        "owner": "${{ github.repository_owner }}",
        "repositories": "${{ github.event.repository.name }}",
        "permission-contents": "write",
    }
    if mint.get("with") != expected_mint:
        problems.append("App token is not exact current-repository contents-write scope")

    guard = next((step for step in steps if step.get("name") == "Require the default-branch revision"), {})
    guard_run = guard.get("run") or ""
    guard_env = guard.get("env") or {}
    if guard_env != {
        "DISPATCH_REF": "${{ github.ref }}",
        "DEFAULT_BRANCH": "${{ github.event.repository.default_branch }}",
    } or '"refs/heads/$DEFAULT_BRANCH"' not in guard_run:
        problems.append("canary is not bound to the default-branch dispatch revision")

    push_env = push.get("env") or {}
    push_run = push.get("run") or ""
    if push_env.get("CANARY_BRANCH_REF") != "refs/heads/develop":
        problems.append("protected canary branch is not fixed to develop")
    version = str(push_env.get("CANARY_VERSION") or "")
    if version != "v0.0.1-release-app-canary.${{ github.run_id }}.${{ github.run_attempt }}":
        problems.append("canary tag is not a fixed run-unique SemVer prerelease")
    required_push_fragments = (
        'ls-remote --refs "$remote_url" "$CANARY_BRANCH_REF" "$tag_ref"',
        'python3 "$GITHUB_WORKSPACE/scripts/changelog.py" release',
        'push --atomic origin',
        '"$release_commit:$CANARY_BRANCH_REF"',
        '"$tag_ref"',
        'echo "pushed=true"',
        '"${tag_ref}^{}"',
        'test "$remote_branch_commit" = "$release_commit"',
        'test "$remote_tag_object" = "$tag_object"',
        'test "$remote_tag_commit" = "$release_commit"',
    )
    for fragment in required_push_fragments:
        if fragment not in push_run:
            problems.append(f"push proof lacks {fragment}")

    receipt = next((step for step in steps if step.get("name") == "Retain the canary receipt"), {})
    receipt_run = receipt.get("run") or ""
    receipt_env = receipt.get("env") or {}
    expected_receipt_env = {
        "APP_SLUG": "${{ steps.release-app-token.outputs.app-slug }}",
        "INSTALLATION_ID": "${{ steps.release-app-token.outputs.installation-id }}",
        "RELEASE_COMMIT": "${{ steps.push.outputs.release-commit }}",
        "CANARY_VERSION": "${{ steps.push.outputs.version }}",
    }
    if receipt_env != expected_receipt_env:
        problems.append("receipt does not bind App identity and release outputs")
    for fragment in (
        "$GITHUB_STEP_SUMMARY",
        "actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT",
        "main-protection",
        "18098028",
        "refs/heads/develop",
        "does not exercise the default branch ref itself",
    ):
        if fragment not in receipt_run:
            problems.append(f"retained receipt lacks {fragment}")

    cleanup = next(
        (step for step in steps if step.get("name") == "Delete only this run's verified canary refs"),
        {},
    )
    cleanup_run = cleanup.get("run") or ""
    if str(cleanup.get("if") or "") != "always() && steps.push.outputs.pushed == 'true'":
        problems.append("cleanup is not gated on this run recording a successful push")
    cleanup_env = cleanup.get("env") or {}
    if cleanup_env.get("RELEASE_COMMIT") != "${{ steps.push.outputs.release-commit }}" or cleanup_env.get(
        "TAG_OBJECT"
    ) != "${{ steps.push.outputs.tag-object }}":
        problems.append("cleanup ownership is not bound to this run's commit and tag object")
    for fragment in (
        '"$remote_branch_commit" != "$RELEASE_COMMIT"',
        '"$remote_tag_object" != "$TAG_OBJECT"',
        '"$remote_tag_commit" != "$RELEASE_COMMIT"',
        "refusing cleanup",
        'push --atomic "$remote_url"',
        '":$branch_ref"',
        '":$tag_ref"',
        'ls-remote --refs "$remote_url" "$branch_ref" "$tag_ref"',
        "$GITHUB_STEP_SUMMARY",
    ):
        if fragment not in cleanup_run:
            problems.append(f"ownership-checked atomic cleanup lacks {fragment}")
    if "${{ inputs." in raw or "repository:" in raw or "CANARY_BRANCH_REF: ${{" in raw:
        problems.append("canary exposes a user-controlled target")
    return problems


def rejected(label: str, document: dict, raw: str) -> None:
    if not validate(document, raw):
        raise AssertionError(f"mutation survived: {label}")
    print(f"ok - rejects {label}")


def main() -> int:
    raw = WORKFLOW.read_text(encoding="utf-8")
    document = yaml.safe_load(raw)
    problems = validate(document, raw)
    if problems:
        print("FAIL - " + "; ".join(problems))
        return 1
    print("ok - protected release App canary contract is bounded and recoverable")

    job = document["jobs"]["canary"]
    steps = job["steps"]
    mint_index = next(i for i, step in enumerate(steps) if step.get("id") == "release-app-token")
    push_index = next(i for i, step in enumerate(steps) if step.get("id") == "push")
    checkout_index = next(
        i for i, step in enumerate(steps) if str(step.get("uses", "")).startswith("actions/checkout@")
    )
    guard_index = next(i for i, step in enumerate(steps) if step.get("name") == "Require the default-branch revision")
    cleanup_index = next(
        i for i, step in enumerate(steps) if step.get("name") == "Delete only this run's verified canary refs"
    )
    receipt_index = next(i for i, step in enumerate(steps) if step.get("name") == "Retain the canary receipt")

    mutants: list[tuple[str, dict, str]] = []
    mutant = copy.deepcopy(document)
    triggers(mutant)["push"] = {"branches": ["main"]}
    mutants.append(("a push trigger", mutant, raw))
    mutant = copy.deepcopy(document)
    triggers(mutant)["workflow_dispatch"] = {"inputs": {"ref": {"required": True}}}
    mutants.append(("a user-controlled dispatch input", mutant, raw))
    mutant = copy.deepcopy(document)
    mutant["jobs"]["canary"]["steps"][mint_index]["uses"] = "actions/create-github-app-token@v3"
    mutants.append(("a mutable token action ref", mutant, raw))
    mutant = copy.deepcopy(document)
    mutant["jobs"]["canary"]["steps"][checkout_index]["uses"] = "actions/checkout@main"
    mutants.append(("a mutable checkout action ref", mutant, raw))
    mutant = copy.deepcopy(document)
    mutant["jobs"]["canary"]["steps"][guard_index]["env"]["DEFAULT_BRANCH"] = "main"
    mutants.append(("a canary not bound to repository default-branch metadata", mutant, raw))
    for key in ("owner", "repositories", "permission-contents"):
        mutant = copy.deepcopy(document)
        del mutant["jobs"]["canary"]["steps"][mint_index]["with"][key]
        mutants.append((f"token mint without {key}", mutant, raw))
    mutant = copy.deepcopy(document)
    mutant["jobs"]["canary"]["steps"][push_index]["env"]["CANARY_BRANCH_REF"] = "refs/heads/main"
    mutants.append(("a canary branch other than fixed develop", mutant, raw))
    mutant = copy.deepcopy(document)
    mutant["jobs"]["canary"]["steps"][push_index]["env"]["CANARY_VERSION"] = "${{ inputs.version }}"
    mutants.append(("a user-controlled or non-unique canary tag", mutant, raw))
    mutant = copy.deepcopy(document)
    mutant["jobs"]["canary"]["steps"][push_index]["run"] = mutant["jobs"]["canary"]["steps"][push_index][
        "run"
    ].replace("push --atomic origin", "push origin")
    mutants.append(("a non-atomic canary push", mutant, raw))
    mutant = copy.deepcopy(document)
    mutant["jobs"]["canary"]["steps"][cleanup_index]["if"] = "always()"
    mutants.append(("cleanup without successful-push ownership gate", mutant, raw))
    mutant = copy.deepcopy(document)
    mutant["jobs"]["canary"]["steps"][cleanup_index]["run"] = mutant["jobs"]["canary"]["steps"][cleanup_index][
        "run"
    ].replace('"$remote_tag_object" != "$TAG_OBJECT"', '"$remote_tag_object" != ""')
    mutants.append(("cleanup without exact tag-object ownership", mutant, raw))
    mutant = copy.deepcopy(document)
    mutant["jobs"]["canary"]["steps"][receipt_index]["run"] = "echo receipt"
    mutants.append(("a non-retained or incomplete receipt", mutant, raw))

    for label, mutant, mutant_raw in mutants:
        rejected(label, mutant, mutant_raw)
    return 0


if __name__ == "__main__":
    sys.exit(main())
