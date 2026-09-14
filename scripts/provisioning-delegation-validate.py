#!/usr/bin/env python3
"""Validate an owner-approved provisioning delegation grant against the canonical contract.

The validator reads documents only. It never contacts GitHub, never reads a
credential, and never treats its own output as authorization: a grant is authority
only when an owner issued it, a reviewed plan pins it, and the contract is activated.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONTRACT = ROOT / "config/provisioning-delegation-contract.json"
DEFAULT_INVENTORY = ROOT / "config/app-role-custody-inventory.json"
GRANT_SCHEMA = "verjson-provisioning-delegation-grant/v1"
SHA = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]*")
PROHIBITED_SHORTCUTS = ("approved", "unattended", "auto_approve", "model_approval")
GRANT_FIELDS = {
    "schema", "grant_id", "issuer", "executor", "contract_pin", "cohort",
    "effects", "owner_consent", "evidence", "expiry", "revocation",
}


class InputError(Exception):
    """The grant, contract, or inventory could not be read as a document."""


def load(path: Path, label: str) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InputError(f"{label} is unreadable: {error}") from None
    if not isinstance(document, dict):
        raise InputError(f"{label} must be a JSON object")
    return document


def text(value: Any) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def instant(value: Any) -> dt.datetime | None:
    raw = text(value)
    if raw is None or not raw.endswith("Z"):
        return None
    try:
        return dt.datetime.fromisoformat(raw[:-1]).replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def hosted_reference(value: Any, hosts: list[str]) -> bool:
    raw = text(value)
    return raw is not None and any(raw.startswith(f"https://{host}/") for host in hosts)


def check_shape(grant: dict[str, Any]) -> list[str]:
    reasons = []
    if grant.get("schema") != GRANT_SCHEMA:
        reasons.append("grant-schema-unrecognized")
    if set(grant) != GRANT_FIELDS:
        reasons.append("grant-fields-unexpected")
    if text(grant.get("grant_id")) is None or IDENTIFIER.fullmatch(str(grant.get("grant_id"))) is None:
        reasons.append("grant-id-invalid")
    if any(shortcut in grant for shortcut in PROHIBITED_SHORTCUTS):
        reasons.append("approval-shortcut-is-not-authority")
    return reasons


def check_parties(grant: dict[str, Any], contract: dict[str, Any]) -> list[str]:
    reasons = []
    issuer = grant.get("issuer") if isinstance(grant.get("issuer"), dict) else {}
    executor = grant.get("executor") if isinstance(grant.get("executor"), dict) else {}
    issuer_identity = text(issuer.get("identity"))
    executor_identity = text(executor.get("identity"))
    if issuer.get("kind") not in contract["issuer"]["permittedKinds"] or issuer_identity is None:
        reasons.append("issuer-is-not-an-owner")
    if text(issuer.get("organization")) is None:
        reasons.append("issuer-organization-missing")
    if executor.get("kind") not in contract["executor"]["permittedKinds"] or executor_identity is None:
        reasons.append("executor-identity-missing")
    if issuer_identity is not None and issuer_identity == executor_identity:
        reasons.append("self-issued-grant-is-not-authority")
    return reasons


def check_pin(grant: dict[str, Any], contract: dict[str, Any]) -> list[str]:
    pin = grant.get("contract_pin") if isinstance(grant.get("contract_pin"), dict) else {}
    reasons = []
    if pin.get("repository") != contract["contractPin"]["repository"]:
        reasons.append("contract-pin-repository-unexpected")
    if SHA.fullmatch(str(pin.get("sha"))) is None:
        reasons.append("contract-pin-is-not-immutable")
    if text(pin.get("contract_version")) is None:
        reasons.append("contract-version-missing")
    return reasons


def check_evidence(grant: dict[str, Any], contract: dict[str, Any]) -> list[str]:
    evidence = grant.get("evidence") if isinstance(grant.get("evidence"), dict) else {}
    review = evidence.get("review") if isinstance(evidence.get("review"), dict) else {}
    executor = grant.get("executor") if isinstance(grant.get("executor"), dict) else {}
    hosts = contract["evidence"]["requiredReviewHosts"]
    approvers = review.get("approved_by")
    reasons = []
    if DIGEST.fullmatch(str(evidence.get("plan_digest"))) is None:
        reasons.append("plan-digest-missing-or-weak")
    if not hosted_reference(review.get("reference"), hosts):
        reasons.append("review-reference-is-not-hosted")
    if not isinstance(approvers, list) or not approvers or any(text(name) is None for name in approvers):
        reasons.append("review-approver-missing")
    elif text(executor.get("identity")) in [text(name) for name in approvers]:
        reasons.append("executor-cannot-approve-its-own-plan")
    return reasons


def check_window(grant: dict[str, Any], contract: dict[str, Any], now: dt.datetime) -> list[str]:
    expiry = grant.get("expiry") if isinstance(grant.get("expiry"), dict) else {}
    start = instant(expiry.get("not_before"))
    end = instant(expiry.get("not_after"))
    reasons = []
    if start is None or end is None:
        return ["expiry-window-invalid"]
    if end <= start:
        reasons.append("expiry-window-invalid")
    elif end - start > dt.timedelta(days=contract["expiry"]["maximumDurationDays"]):
        reasons.append("expiry-window-too-long")
    if now < start or now >= end:
        reasons.append("grant-not-in-force")
    return reasons


def check_revocation(grant: dict[str, Any], contract: dict[str, Any]) -> list[str]:
    revocation = grant.get("revocation") if isinstance(grant.get("revocation"), dict) else {}
    hosts = contract["evidence"]["requiredReviewHosts"]
    if revocation.get("surface") not in contract["revocation"]["requiredSurfaces"]:
        return ["revocation-surface-missing"]
    if not hosted_reference(revocation.get("reference"), hosts):
        return ["revocation-reference-is-not-hosted"]
    return []


def check_cohort(grant: dict[str, Any], contract: dict[str, Any], inventory: dict[str, Any]) -> tuple[list[str], list[str], list[str]]:
    cohort = grant.get("cohort") if isinstance(grant.get("cohort"), dict) else {}
    targets = cohort.get("targets")
    roles = inventory["roles"]
    reasons: list[str] = []
    named: list[str] = []
    effects: set[str] = set()
    if cohort.get("completeness") != contract["cohort"]["requiredCompleteness"]:
        reasons.append("cohort-inventory-incomplete")
    if not isinstance(targets, list) or not targets:
        return reasons + ["cohort-targets-missing"], named, []
    for target in targets:
        if not isinstance(target, dict):
            reasons.append("cohort-target-malformed")
            continue
        role_id = text(target.get("role_id"))
        if role_id is None or role_id not in roles:
            reasons.append("cohort-target-role-unknown")
            continue
        if role_id in named:
            reasons.append("cohort-target-duplicated")
            continue
        named.append(role_id)
        role = roles[role_id]
        if target.get("permission_ceiling") != role["permissionCeiling"]:
            reasons.append(f"permission-ceiling-exceeded:{role_id}")
        selection = target.get("repository_selection")
        repositories = target.get("repositories")
        if selection not in {"all", "selected"} or not isinstance(repositories, list):
            reasons.append(f"repository-selection-invalid:{role_id}")
        elif selection == "selected" and not repositories:
            reasons.append(f"selected-repository-inventory-incomplete:{role_id}")
        elif selection == "all" and repositories:
            reasons.append(f"repository-selection-invalid:{role_id}")
        requested = target.get("effects")
        if not isinstance(requested, list) or any(text(effect) is None for effect in requested):
            reasons.append(f"target-effects-invalid:{role_id}")
            continue
        for effect in requested:
            effects.add(effect)
            if effect not in contract["effects"]["vocabulary"]:
                reasons.append(f"effect-outside-vocabulary:{effect}")
            elif effect not in role["permittedEffects"]:
                reasons.append(f"effect-not-permitted-for-role:{role_id}:{effect}")
    return reasons, named, sorted(effects)


def check_consent(grant: dict[str, Any], contract: dict[str, Any], effects: list[str]) -> list[str]:
    declared = grant.get("effects")
    consent = grant.get("owner_consent")
    hosts = contract["evidence"]["requiredReviewHosts"]
    gated = set(contract["effects"]["ownerConsentRequired"])
    reasons = []
    if not isinstance(declared, list) or sorted({str(effect) for effect in declared}) != effects:
        reasons.append("declared-effects-differ-from-plan")
    if not isinstance(consent, list):
        return reasons + ["owner-consent-missing"]
    consented = set()
    for record in consent:
        if not isinstance(record, dict):
            reasons.append("owner-consent-malformed")
            continue
        effect = text(record.get("effect"))
        approvers = record.get("approved_by")
        if effect is None or not hosted_reference(record.get("reference"), hosts):
            reasons.append("owner-consent-malformed")
            continue
        if not isinstance(approvers, list) or not approvers or any(text(name) is None for name in approvers):
            reasons.append(f"owner-consent-approver-missing:{effect}")
            continue
        consented.add(effect)
    for effect in effects:
        if effect in gated and effect not in consented:
            reasons.append(f"owner-consent-required:{effect}")
    for effect in sorted(consented - set(effects)):
        reasons.append(f"owner-consent-exceeds-plan:{effect}")
    return reasons


def validate(grant: dict[str, Any], contract: dict[str, Any], inventory: dict[str, Any], now: dt.datetime) -> dict[str, Any]:
    reasons = check_shape(grant)
    if contract.get("activation", {}).get("status") != "active":
        reasons.append("contract-not-activated")
    if inventory.get("schema") != "verjson-app-role-custody-inventory/v1" or not isinstance(inventory.get("roles"), dict):
        raise InputError("custody inventory is not a recognized role inventory")
    reasons += check_parties(grant, contract)
    reasons += check_pin(grant, contract)
    reasons += check_evidence(grant, contract)
    reasons += check_window(grant, contract, now)
    reasons += check_revocation(grant, contract)
    cohort_reasons, targets, effects = check_cohort(grant, contract, inventory)
    reasons += cohort_reasons
    reasons += check_consent(grant, contract, effects)
    return {
        "grant_id": grant.get("grant_id") if isinstance(grant.get("grant_id"), str) else None,
        "authorization": "granted" if not reasons else "withheld",
        "reasons": sorted(dict.fromkeys(reasons)),
        "effects": effects,
        "targets": targets,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grant", type=Path, required=True)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    parser.add_argument("--now", default=None, help="UTC instant used to evaluate the grant window")
    arguments = parser.parse_args()
    try:
        now = dt.datetime.now(dt.timezone.utc) if arguments.now is None else instant(arguments.now)
        if now is None:
            raise InputError("--now must be a UTC instant such as 2026-09-14T00:00:00Z")
        receipt = validate(
            load(arguments.grant, "grant"),
            load(arguments.contract, "delegation contract"),
            load(arguments.inventory, "custody inventory"),
            now,
        )
    except (InputError, KeyError, TypeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(json.dumps(receipt, indent=2, sort_keys=True))
    return 0 if receipt["authorization"] == "granted" else 1


if __name__ == "__main__":
    raise SystemExit(main())
