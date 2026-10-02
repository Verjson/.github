#!/usr/bin/env python3
"""Validate and expand the reviewed OCI candidate registry destinations."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


class DestinationError(ValueError):
    pass


GHCR_OWNER = re.compile(r"^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*$")
GAR_NAMESPACE = re.compile(
    r"^(?P<location>[a-z]+(?:-[a-z0-9]+)*)-docker\.pkg\.dev/"
    r"(?P<project>[a-z][a-z0-9-]{4,28}[a-z0-9])/"
    r"(?P<repository>[a-z][a-z0-9-]{0,62}[a-z0-9])$"
)
WIF_PROVIDER = re.compile(
    r"^projects/[0-9]+/locations/global/workloadIdentityPools/"
    r"[A-Za-z0-9_-]+/providers/[A-Za-z0-9_-]+$"
)
SERVICE_ACCOUNT = re.compile(
    r"^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$"
)
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
TAG = re.compile(
    r"^(?:sha-[0-9a-f]{40}|(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-rc\.[0-9]+\.[0-9]+)?)$"
)
DEFAULT_CANDIDATE_RETENTION_DAYS = 88


def _object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise DestinationError(f"{field} must be an object")
    return value


def _string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise DestinationError(f"{field} must be a non-empty string")
    return value


def normalize_destinations(config: dict[str, Any], owner: str) -> list[dict[str, Any]]:
    owner = owner.lower()
    if not GHCR_OWNER.fullmatch(owner):
        raise DestinationError("repository owner is not a valid GHCR namespace")

    primary_namespace = _string(config.get("registryNamespace"), "registryNamespace").rstrip("/")
    expected_primary = f"ghcr.io/{owner}"
    if primary_namespace != expected_primary:
        raise DestinationError("registryNamespace must be the repository owner's GHCR namespace")

    raw_destinations = config.get("registryDestinations")
    if raw_destinations is None:
        raw_destinations = [{"provider": "ghcr", "namespace": primary_namespace}]
    if not isinstance(raw_destinations, list) or not raw_destinations:
        raise DestinationError("registryDestinations must be a non-empty array")

    destinations: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, raw in enumerate(raw_destinations):
        field = f"registryDestinations[{index}]"
        item = _object(raw, field)
        provider = _string(item.get("provider"), f"{field}.provider")
        namespace = _string(item.get("namespace"), f"{field}.namespace").rstrip("/")
        if namespace in seen:
            raise DestinationError("registryDestinations must not contain duplicate namespaces")
        seen.add(namespace)

        if provider == "ghcr":
            if index != 0 or namespace != expected_primary:
                raise DestinationError("GHCR must be the first destination and match registryNamespace")
            if set(item) - {"provider", "namespace", "candidateRetentionDays"}:
                raise DestinationError(f"{field} contains unsupported GHCR settings")
            retention_days = item.get("candidateRetentionDays", DEFAULT_CANDIDATE_RETENTION_DAYS)
            if not isinstance(retention_days, int) or not 1 <= retention_days <= DEFAULT_CANDIDATE_RETENTION_DAYS:
                raise DestinationError(f"{field}.candidateRetentionDays must be 1 through {DEFAULT_CANDIDATE_RETENTION_DAYS}")
            destinations.append({
                "provider": provider,
                "namespace": namespace,
                "registryHost": "ghcr.io",
                "candidateRetentionDays": retention_days,
            })
        elif provider == "gar":
            if GAR_NAMESPACE.fullmatch(namespace) is None:
                raise DestinationError(f"{field}.namespace must be a GAR Docker repository namespace")
            if set(item) != {"provider", "namespace", "workloadIdentityProvider", "serviceAccount", "candidateRetentionDays"}:
                raise DestinationError(f"{field} must define only its namespace, OIDC identity, and candidate retention")
            identity_provider = _string(item.get("workloadIdentityProvider"), f"{field}.workloadIdentityProvider")
            service_account = _string(item.get("serviceAccount"), f"{field}.serviceAccount")
            retention_days = item.get("candidateRetentionDays")
            if WIF_PROVIDER.fullmatch(identity_provider) is None:
                raise DestinationError(f"{field}.workloadIdentityProvider is not a Google WIF provider resource")
            if SERVICE_ACCOUNT.fullmatch(service_account) is None:
                raise DestinationError(f"{field}.serviceAccount is not a Google service-account address")
            if not isinstance(retention_days, int) or not 1 <= retention_days <= DEFAULT_CANDIDATE_RETENTION_DAYS:
                raise DestinationError(f"{field}.candidateRetentionDays must be 1 through {DEFAULT_CANDIDATE_RETENTION_DAYS}")
            if destinations and destinations[0]["provider"] != "ghcr":
                raise DestinationError("GAR destinations require GHCR as the canonical build and provenance source")
            if any(destination["provider"] == "gar" for destination in destinations):
                raise DestinationError("only one GAR destination is currently supported")
            destinations.append({
                "provider": provider,
                "namespace": namespace,
                "registryHost": namespace.split("/", 1)[0],
                "workloadIdentityProvider": identity_provider,
                "serviceAccount": service_account,
                "candidateRetentionDays": retention_days,
            })
        else:
            raise DestinationError(f"{field}.provider is unsupported")

    if destinations[0]["provider"] != "ghcr":
        raise DestinationError("GHCR must remain the canonical build and provenance source")
    return destinations


def expand_image_destinations(
    config: dict[str, Any], owner: str, image: dict[str, Any]
) -> list[dict[str, Any]]:
    destinations = normalize_destinations(config, owner)
    repository = _string(image.get("repository"), "image.repository")
    primary = destinations[0]["namespace"]
    if not repository.startswith(primary + "/"):
        raise DestinationError("image.repository escapes the canonical GHCR namespace")
    suffix = repository[len(primary):]
    if any(part in {"", ".", ".."} for part in suffix[1:].split("/")):
        raise DestinationError("image.repository contains an unsafe path")
    return [
        {**destination, "repository": destination["namespace"] + suffix}
        for destination in destinations
    ]


def _skopeo(arguments: list[str]) -> tuple[int, bytes, bytes]:
    try:
        result = subprocess.run(
            ["skopeo", *arguments],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise DestinationError("skopeo is unavailable") from error
    return result.returncode, result.stdout, result.stderr


def _remote_digest(reference: str, authfile: Path) -> str | None:
    status, output, error = _skopeo([
        "--authfile", str(authfile), "inspect", "--raw", f"docker://{reference}"
    ])
    if status:
        message = error.decode("utf-8", errors="replace").lower()
        if any(marker in message for marker in ("manifest unknown", "manifest not found", "no such manifest")):
            return None
        raise DestinationError("registry observation failed")
    return "sha256:" + hashlib.sha256(output).hexdigest()


def mirror_candidate(
    config: dict[str, Any], owner: str, variant: str, provider: str,
    tag: str, digest: str, authfile: Path, published_at: str | None = None,
) -> dict[str, str]:
    if not TAG.fullmatch(tag) or not DIGEST.fullmatch(digest):
        raise DestinationError("candidate tag or digest is malformed")
    if not authfile.is_absolute() or not authfile.is_file():
        raise DestinationError("registry authfile is unavailable")
    images = config.get("images")
    if not isinstance(images, list):
        raise DestinationError("images must be a non-empty array")
    image = next(
        (item for item in images if isinstance(item, dict) and item.get("variant") == variant),
        None,
    )
    if image is None:
        raise DestinationError("image variant is not configured")
    destinations = expand_image_destinations(config, owner, image)
    source = destinations[0]["repository"]
    destination = next((item for item in destinations if item["provider"] == provider), None)
    if destination is None:
        raise DestinationError("registry provider is not configured for this candidate")
    target = f"{destination['repository']}:{tag}"
    existing = _remote_digest(target, authfile)
    if existing is not None and existing != digest:
        raise DestinationError("destination tag already names a different digest")
    if existing is None:
        status, _, _ = _skopeo([
            "--src-authfile", str(authfile),
            "--dest-authfile", str(authfile),
            "copy", "--all", "--preserve-digests",
            f"docker://{source}@{digest}", f"docker://{target}",
        ])
        if status:
            raise DestinationError("registry mirror copy failed")
    observed = _remote_digest(target, authfile)
    if observed != digest:
        raise DestinationError("destination digest differs from the candidate digest")
    receipt = {"provider": provider, "repository": destination["repository"], "digest": digest}
    return _with_candidate_expiry(receipt, config, owner, variant, digest, published_at)


def _with_candidate_expiry(
    receipt: dict[str, str], config: dict[str, Any], owner: str, variant: str,
    digest: str, published_at: str | None,
) -> dict[str, str]:
    if published_at is None:
        return receipt
    destination = next(
        item for item in manifest_destinations(config, owner, variant, digest, published_at)
        if item["provider"] == receipt["provider"]
    )
    return {
        **receipt,
        "variant": variant,
        "candidateExpiresAt": destination["candidateExpiresAt"],
        "verifiedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def manifest_destinations(
    config: dict[str, Any], owner: str, variant: str, digest: str, published_at: str
) -> list[dict[str, str]]:
    if not DIGEST.fullmatch(digest):
        raise DestinationError("candidate digest is malformed")
    try:
        published = datetime.fromisoformat(published_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise DestinationError("candidate published-at time is malformed") from error
    if published.tzinfo is None or published.utcoffset() != timedelta(0):
        raise DestinationError("candidate published-at time must be UTC")
    images = config.get("images")
    if not isinstance(images, list):
        raise DestinationError("images must be a non-empty array")
    image = next(
        (item for item in images if isinstance(item, dict) and item.get("variant") == variant),
        None,
    )
    if image is None:
        raise DestinationError("image variant is not configured")
    published = published.astimezone(timezone.utc)
    return [
        {
            "provider": destination["provider"],
            "repository": destination["repository"],
            "digest": digest,
            "candidateExpiresAt": (
                published + timedelta(days=destination["candidateRetentionDays"])
            ).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        for destination in expand_image_destinations(config, owner, image)
    ]


def verify_candidate(
    config: dict[str, Any], owner: str, variant: str, provider: str,
    tag: str, digest: str, authfile: Path, published_at: str | None = None,
) -> dict[str, str]:
    if not TAG.fullmatch(tag) or not DIGEST.fullmatch(digest):
        raise DestinationError("candidate tag or digest is malformed")
    if not authfile.is_absolute() or not authfile.is_file():
        raise DestinationError("registry authfile is unavailable")
    images = config.get("images")
    if not isinstance(images, list):
        raise DestinationError("images must be a non-empty array")
    image = next(
        (item for item in images if isinstance(item, dict) and item.get("variant") == variant),
        None,
    )
    if image is None:
        raise DestinationError("image variant is not configured")
    destination = next(
        (item for item in expand_image_destinations(config, owner, image) if item["provider"] == provider),
        None,
    )
    if destination is None:
        raise DestinationError("registry provider is not configured for this candidate")
    observed = _remote_digest(f"{destination['repository']}:{tag}", authfile)
    if observed != digest:
        raise DestinationError("candidate destination is expired or resolves to a different digest")
    receipt = {"provider": provider, "repository": destination["repository"], "digest": digest}
    return _with_candidate_expiry(receipt, config, owner, variant, digest, published_at)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate and expand OCI registry destinations")
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--mirror-provider")
    parser.add_argument("--variant")
    parser.add_argument("--tag")
    parser.add_argument("--digest")
    parser.add_argument("--authfile", type=Path)
    parser.add_argument("--published-at")
    parser.add_argument("--verify-provider")
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text(encoding="utf-8"))
        if not isinstance(config, dict):
            raise DestinationError("candidate config must contain an object")
        normalized = normalize_destinations(config, args.owner)
        images = config.get("images")
        if not isinstance(images, list) or not images:
            raise DestinationError("images must be a non-empty array")
        expanded = []
        for image in images:
            expanded.append({
                "variant": _string(_object(image, "image").get("variant"), "image.variant"),
                "destinations": expand_image_destinations(config, args.owner, image),
            })
        if args.published_at is not None:
            if not args.variant or not args.digest:
                raise DestinationError("manifest mode requires a variant and digest")
            record = manifest_destinations(
                config, args.owner, args.variant, args.digest, args.published_at
            )
            print(json.dumps(record, separators=(",", ":")))
            return 0
        if args.mirror_provider is not None:
            if not all((args.variant, args.tag, args.digest, args.authfile)):
                raise DestinationError("mirror mode requires a variant, tag, digest, and authfile")
            receipt = mirror_candidate(
                config, args.owner, args.variant, args.mirror_provider,
                args.tag, args.digest, args.authfile, args.published_at,
            )
            print(json.dumps(receipt, separators=(",", ":")))
            return 0
        if args.verify_provider is not None:
            if not all((args.variant, args.tag, args.digest, args.authfile)):
                raise DestinationError("verification mode requires a variant, tag, digest, and authfile")
            receipt = verify_candidate(
                config, args.owner, args.variant, args.verify_provider,
                args.tag, args.digest, args.authfile, args.published_at,
            )
            print(json.dumps(receipt, separators=(",", ":")))
            return 0
    except (OSError, json.JSONDecodeError, DestinationError) as error:
        print(f"container registry destinations rejected: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"destinations": normalized, "images": expanded}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
