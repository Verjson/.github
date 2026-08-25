#!/usr/bin/env python3
"""Observe and reconcile strictly provable npm dependency-PR supersession."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Any

SCHEMA = "canonical-dependency-supersession/v1"
ALLOWED_BOTS = {"renovate[bot]", "dependabot[bot]"}
MANIFEST = re.compile(r"(^|/)package\.json$")
LOCKFILE = re.compile(r"(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock)$")
VERSION = re.compile(r"^(?P<prefix>[~^]?)(?P<major>0|[1-9][0-9]*)\.(?P<minor>0|[1-9][0-9]*)\.(?P<patch>0|[1-9][0-9]*)(?:-(?P<pre>[0-9A-Za-z.-]+))?$")
SECTIONS = ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies")


class Refusal(RuntimeError):
    pass


def gh(path: str, method: str = "GET", fields: dict[str, str] | None = None) -> Any:
    command = ["gh", "api", "--method", method, path]
    for key, value in (fields or {}).items():
        command.extend(["-f", f"{key}={value}"])
    result = subprocess.run(command, check=False, text=True, capture_output=True)
    if result.returncode:
        raise Refusal(f"GitHub API request failed for {path}")
    try:
        return json.loads(result.stdout) if result.stdout.strip() else None
    except json.JSONDecodeError as error:
        raise Refusal(f"GitHub API returned malformed JSON for {path}") from error


def complete_pr(value: Any, allow_closed: bool = False) -> dict[str, Any]:
    required = ("number", "state", "base", "head", "user", "draft")
    if not isinstance(value, dict) or any(key not in value for key in required):
        raise Refusal("incomplete pull-request response")
    for ref in ("base", "head"):
        if not isinstance(value[ref], dict) or not isinstance(value[ref].get("sha"), str) or not re.fullmatch(r"[0-9a-f]{40}", value[ref]["sha"]):
            raise Refusal(f"incomplete {ref} ref")
    user = value["user"]
    if not isinstance(user, dict) or user.get("type") != "Bot" or user.get("login") not in ALLOWED_BOTS or not isinstance(user.get("id"), int):
        raise Refusal("pull request is not authored by an approved App bot")
    if value["state"] not in ({"open", "closed"} if allow_closed else {"open"}) or value["draft"] is not False:
        raise Refusal("pull request is not an open non-draft update")
    labels = value.get("labels")
    if not isinstance(labels, list) or any(not isinstance(label, dict) or not isinstance(label.get("name"), str) for label in labels):
        raise Refusal("pull-request labels are incomplete")
    unsafe = re.compile(r"(^|[-_ ])(security|rollback|downgrade|exception)([-_ ]|$)", re.IGNORECASE)
    if any(unsafe.search(label["name"]) for label in labels):
        raise Refusal("security exception, rollback, or downgrade label")
    return value


def version(value: Any) -> tuple[int, int, int, int, str]:
    if not isinstance(value, str) or not (match := VERSION.fullmatch(value)):
        raise Refusal(f"unsupported or ambiguous npm version: {value!r}")
    pre = match.group("pre")
    if pre is not None:
        raise Refusal(f"prerelease versions are not totally ordered by this contract: {value!r}")
    return (int(match.group("major")), int(match.group("minor")), int(match.group("patch")), 1 if pre is None else 0, pre or "")


def content(repo: str, path: str, ref: str) -> tuple[str, dict[str, Any]]:
    response = gh(f"repos/{repo}/contents/{path}?ref={ref}")
    if not isinstance(response, dict) or response.get("encoding") != "base64" or not isinstance(response.get("content"), str) or not isinstance(response.get("sha"), str):
        raise Refusal("incomplete contents response")
    import base64
    try:
        raw = base64.b64decode(response["content"], validate=False)
        parsed = json.loads(raw)
    except (ValueError, json.JSONDecodeError) as error:
        raise Refusal(f"malformed manifest {path}") from error
    if not isinstance(parsed, dict):
        raise Refusal(f"manifest {path} is not an object")
    return response["sha"], parsed


def transitions(repo: str, pr: dict[str, Any]) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    files = gh(f"repos/{repo}/pulls/{pr['number']}/files?per_page=100")
    if not isinstance(files, list) or len(files) >= 100:
        raise Refusal("file response is malformed or potentially truncated")
    identities: list[dict[str, str]] = []
    changes: list[dict[str, str]] = []
    seen: set[tuple[str, str, str]] = set()
    for item in files:
        if not isinstance(item, dict) or not isinstance(item.get("filename"), str) or not isinstance(item.get("sha"), str) or item.get("status") not in {"modified"}:
            raise Refusal("unsupported file operation or incomplete file response")
        path = item["filename"]
        if not (MANIFEST.search(path) or LOCKFILE.search(path)):
            raise Refusal("mixed-purpose pull request")
        identities.append({"path": path, "blob": item["sha"]})
        if LOCKFILE.search(path):
            continue
        base_blob, before = content(repo, path, pr["base"]["sha"])
        head_blob, after = content(repo, path, pr["head"]["sha"])
        if head_blob != item["sha"]:
            raise Refusal("file list and immutable head blob disagree")
        identities[-1]["baseBlob"] = base_blob
        for section in SECTIONS:
            left, right = before.get(section, {}), after.get(section, {})
            if not isinstance(left, dict) or not isinstance(right, dict):
                raise Refusal("dependency section is malformed")
            if set(left) != set(right):
                raise Refusal("dependency addition or removal is not supersession-safe")
            for name in sorted(left):
                if left[name] == right[name]:
                    continue
                key = (path, section, name)
                if key in seen:
                    raise Refusal("duplicate dependency coordinate")
                seen.add(key)
                old_match, new_match = VERSION.fullmatch(str(left[name])), VERSION.fullmatch(str(right[name]))
                if old_match is None or new_match is None or old_match.group("prefix") != new_match.group("prefix"):
                    raise Refusal("dependency range semantics changed or are ambiguous")
                old, new = version(left[name]), version(right[name])
                if new <= old:
                    raise Refusal("downgrade, rollback, or non-increasing update")
                changes.append({"ecosystem": "npm", "manifest": path, "section": section, "name": name, "from": left[name], "to": right[name]})
    if not changes:
        raise Refusal("no supported dependency transition")
    identities.sort(key=lambda x: x["path"])
    changes.sort(key=lambda x: (x["manifest"], x["section"], x["name"]))
    return identities, changes


def snapshot(repo: str, number: int, allow_closed: bool = False) -> dict[str, Any]:
    pr = complete_pr(gh(f"repos/{repo}/pulls/{number}"), allow_closed)
    commits = gh(f"repos/{repo}/pulls/{number}/commits?per_page=100")
    if not isinstance(commits, list) or not commits or len(commits) >= 100:
        raise Refusal("commit response is malformed or potentially truncated")
    for commit in commits:
        actor = commit.get("author") if isinstance(commit, dict) else None
        if not isinstance(actor, dict) or actor.get("type") != "Bot" or actor.get("login") != pr["user"]["login"] or actor.get("id") != pr["user"]["id"]:
            raise Refusal("manual or mixed authorship")
    files, changes = transitions(repo, pr)
    return {"number": pr["number"], "baseRef": pr["base"].get("ref"), "baseSha": pr["base"]["sha"], "headSha": pr["head"]["sha"],
            "author": {"login": pr["user"]["login"], "type": "Bot", "id": pr["user"]["id"]}, "files": files, "transitions": changes}


def covers(candidate: dict[str, Any], replacement: dict[str, Any]) -> bool:
    if candidate["baseRef"] != replacement["baseRef"] or candidate["baseSha"] != replacement["baseSha"]:
        return False
    right = {(x["ecosystem"], x["manifest"], x["section"], x["name"], x["from"]): x for x in replacement["transitions"]}
    for old in candidate["transitions"]:
        new = right.get((old["ecosystem"], old["manifest"], old["section"], old["name"], old["from"]))
        if new is None:
            return False
        old_to, new_to = version(old["to"]), version(new["to"])
        old_match, new_match = VERSION.fullmatch(old["to"]), VERSION.fullmatch(new["to"])
        if old_match is None or new_match is None or old_match.group("prefix") != new_match.group("prefix"):
            return False
        if new_to < old_to:
            return False
    return True


def receipt_id(repo: str, candidate: dict[str, Any], replacement: dict[str, Any]) -> str:
    material = json.dumps({"schema": SCHEMA, "repository": repo, "candidate": candidate, "replacement": replacement}, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(material.encode()).hexdigest()


def observe(repo: str) -> dict[str, Any]:
    meta = gh(f"repos/{repo}")
    if not isinstance(meta, dict) or meta.get("full_name") != repo or not isinstance(meta.get("default_branch"), str):
        raise Refusal("repository identity response is incomplete")
    pulls = gh(f"repos/{repo}/pulls?state=open&per_page=100")
    if not isinstance(pulls, list) or len(pulls) >= 100:
        raise Refusal("open pull-request response is malformed or potentially truncated")
    snapshots, refused = [], []
    for entry in pulls:
        number = entry.get("number") if isinstance(entry, dict) else None
        if not isinstance(number, int):
            raise Refusal("pull-request listing is incomplete")
        try:
            snapshots.append(snapshot(repo, number))
        except Refusal as error:
            refused.append({"number": number, "reason": str(error)})
    proposals = []
    for candidate in snapshots:
        possible = [new for new in snapshots if new["number"] != candidate["number"] and covers(candidate, new)]
        if len(possible) == 1:
            replacement = possible[0]
            proposals.append({"receipt": receipt_id(repo, candidate, replacement), "candidate": candidate, "replacement": replacement})
    return {"schema": SCHEMA, "mode": "observe-only", "repository": repo, "defaultBranch": meta["default_branch"],
            "generatedAt": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(), "proposals": proposals, "refused": refused}


def reconcile(proposal: dict[str, Any], receipt: str, enforce: bool) -> dict[str, Any]:
    if proposal.get("schema") != SCHEMA or proposal.get("mode") != "observe-only" or not re.fullmatch(r"[0-9a-f]{64}", receipt):
        raise Refusal("proposal envelope is malformed")
    matches = [item for item in proposal.get("proposals", []) if isinstance(item, dict) and item.get("receipt") == receipt]
    if len(matches) != 1:
        raise Refusal("receipt is absent or ambiguous")
    item, repo = matches[0], proposal.get("repository")
    if not isinstance(repo, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise Refusal("repository identity is malformed")
    old_number, new_number = item["candidate"]["number"], item["replacement"]["number"]
    old_pr = complete_pr(gh(f"repos/{repo}/pulls/{old_number}"), allow_closed=enforce)
    old, new = snapshot(repo, old_number, allow_closed=enforce), snapshot(repo, new_number)
    if old != item["candidate"] or new != item["replacement"] or receipt_id(repo, old, new) != receipt or not covers(old, new):
        raise Refusal("live state does not match the immutable proposal")
    result = {"schema": SCHEMA, "repository": repo, "candidate": old["number"], "replacement": new["number"], "receipt": receipt, "mode": "enforce" if enforce else "observe-only", "writes": []}
    if not enforce:
        return result
    marker = f"<!-- canonical-dependency-supersession:{receipt} -->"
    comments = gh(f"repos/{repo}/issues/{old['number']}/comments?per_page=100")
    if not isinstance(comments, list) or len(comments) >= 100:
        raise Refusal("comment response is malformed or potentially truncated")
    existing = [comment for comment in comments if isinstance(comment, dict) and marker in str(comment.get("body", "")) and
                isinstance(comment.get("user"), dict) and comment["user"].get("login") == "canonical-dependency-supersession[bot]"]
    if len(existing) > 1:
        raise Refusal("duplicate reconciliation comments")
    if old_pr["state"] == "closed":
        events = gh(f"repos/{repo}/issues/{old['number']}/events?per_page=100")
        closed_by_app = isinstance(events, list) and len(events) < 100 and any(
            isinstance(event, dict) and event.get("event") == "closed" and
            isinstance(event.get("actor"), dict) and event["actor"].get("login") == "canonical-dependency-supersession[bot]"
            for event in events
        )
        if len(existing) == 1 and closed_by_app:
            result["writes"].append("already-reconciled")
            return result
        raise Refusal("closed candidate lacks this reconciler's exact comment and closure event")
    if not existing:
        body = f"Superseded by #{new['number']}. The replacement completely covers this bot-authored dependency update.\n\nImmutable receipt: `{receipt}`\n{marker}"
        gh(f"repos/{repo}/issues/{old['number']}/comments", "POST", {"body": body})
        result["writes"].append("comment")
    after_old, after_new = snapshot(repo, old["number"]), snapshot(repo, new["number"])
    if after_old != old or after_new != new or not covers(after_old, after_new):
        raise Refusal("candidate or replacement changed after comment; refusing closure")
    closed = gh(f"repos/{repo}/pulls/{old['number']}", "PATCH", {"state": "closed"})
    if not isinstance(closed, dict) or closed.get("state") != "closed" or closed.get("number") != old["number"]:
        raise Refusal("closure response is incomplete")
    result["writes"].append("close")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    observer = sub.add_parser("observe")
    observer.add_argument("--repository", required=True)
    observer.add_argument("--output", required=True)
    reconciler = sub.add_parser("reconcile")
    reconciler.add_argument("--proposal", required=True)
    reconciler.add_argument("--receipt", required=True)
    reconciler.add_argument("--output", required=True)
    reconciler.add_argument("--enforce", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "observe":
            result = observe(args.repository)
        else:
            with open(args.proposal, encoding="utf-8") as handle:
                result = reconcile(json.load(handle), args.receipt, args.enforce)
        with open(args.output, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2, sort_keys=True)
            handle.write("\n")
        return 0
    except (Refusal, OSError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
