#!/usr/bin/env python3

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


class ManifestError(ValueError):
    pass


DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
STABLE_VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
CANDIDATE_VERSION = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-rc\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)


def _objects(value: Any, field: str) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise ManifestError(f"{field} must be a non-empty array")
    if any(not isinstance(item, dict) for item in value):
        raise ManifestError(f"{field} entries must be objects")
    return value


def _text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ManifestError(f"{field} must be a non-empty string")
    return value


def _digest(value: Any, field: str) -> str:
    value = _text(value, field)
    if not DIGEST.fullmatch(value):
        raise ManifestError(f"{field} must be a lowercase sha256 digest")
    return value


def _platform_identity(platform: dict[str, Any], field: str) -> tuple[str, str, str]:
    variant = platform.get("variant", "")
    if not isinstance(variant, str):
        raise ManifestError(f"{field}.variant must be a string")
    return (
        _text(platform.get("os"), f"{field}.os"),
        _text(platform.get("architecture"), f"{field}.architecture"),
        variant,
    )


def _index_unique(
    values: list[dict[str, Any]], field: str, identity
) -> dict[Any, dict[str, Any]]:
    indexed: dict[Any, dict[str, Any]] = {}
    for offset, value in enumerate(values):
        key = identity(value, f"{field}[{offset}]")
        if key in indexed:
            raise ManifestError(f"{field} contains duplicate identity {key!r}")
        indexed[key] = value
    return indexed


def validate_manifest(manifest: dict[str, Any], config: dict[str, Any]) -> None:
    if manifest.get("schemaVersion") != 1:
        raise ManifestError("manifest.schemaVersion must be 1")
    if manifest.get("kind") != "container-candidate":
        raise ManifestError("manifest.kind must be container-candidate")

    source = manifest.get("source")
    if not isinstance(source, dict):
        raise ManifestError("manifest.source must be an object")
    expected_repository = _text(config.get("repository"), "config.repository")
    if source.get("repository") != expected_repository:
        raise ManifestError("manifest source repository differs from reviewed config")
    for key in ("commit", "ref", "workflow", "runId", "runAttempt"):
        _text(source.get(key), f"manifest.source.{key}")
    if source["ref"] != "refs/heads/main":
        raise ManifestError("candidate source ref must be refs/heads/main")
    if not re.fullmatch(r"[0-9a-f]{40}", source["commit"]):
        raise ManifestError("manifest.source.commit must be a 40-hex commit")
    if not source["workflow"].startswith(
        "Verjson/.github/.github/workflows/container-candidate.yml@"
    ):
        raise ManifestError("candidate signer workflow differs from expected publisher")

    next_stable = _text(config.get("nextStableVersion"), "config.nextStableVersion")
    if not STABLE_VERSION.fullmatch(next_stable):
        raise ManifestError("config.nextStableVersion must be stable SemVer")
    candidate = _text(manifest.get("candidateVersion"), "manifest.candidateVersion")
    match = CANDIDATE_VERSION.fullmatch(candidate)
    if not match or candidate != f"{next_stable}-rc.{source['runId']}.{source['runAttempt']}":
        raise ManifestError("candidateVersion is not derived from nextStableVersion and source run")

    expected_images = _index_unique(
        _objects(config.get("images"), "config.images"),
        "config.images",
        lambda image, field: _text(image.get("variant"), f"{field}.variant"),
    )
    actual_images = _index_unique(
        _objects(manifest.get("images"), "manifest.images"),
        "manifest.images",
        lambda image, field: _text(image.get("variant"), f"{field}.variant"),
    )
    if actual_images.keys() != expected_images.keys():
        raise ManifestError("manifest variants differ from reviewed config")

    for variant, expected in expected_images.items():
        actual = actual_images[variant]
        if actual.get("repository") != expected.get("repository"):
            raise ManifestError(f"image repository differs for variant {variant!r}")
        repository = _text(actual.get("repository"), f"manifest.images[{variant!r}].repository")
        namespace = _text(config.get("registryNamespace"), "config.registryNamespace").rstrip("/")
        if not repository.startswith(namespace + "/"):
            raise ManifestError(f"image repository escapes registry namespace for variant {variant!r}")
        _digest(actual.get("indexDigest"), f"manifest.images[{variant!r}].indexDigest")
        identities = actual.get("identities")
        if not isinstance(identities, dict):
            raise ManifestError(f"identities must be an object for variant {variant!r}")
        commit_identity = f"sha-{source['commit']}"
        if identities != {
            "commit": commit_identity,
            "candidate": candidate,
        }:
            raise ManifestError(f"immutable identities differ for variant {variant!r}")

        expected_provenance = expected.get("provenance")
        actual_provenance = actual.get("provenance")
        if not isinstance(expected_provenance, dict) or not isinstance(actual_provenance, dict):
            raise ManifestError(f"provenance must be an object for variant {variant!r}")
        for key in ("predicateType",):
            if actual_provenance.get(key) != expected_provenance.get(key):
                raise ManifestError(
                    f"provenance {key} differs for variant {variant!r}"
                )
        if actual_provenance.get("builderIdentity") != source["workflow"]:
            raise ManifestError(f"provenance signer workflow differs for variant {variant!r}")
        if actual_provenance.get("builderIdentity") != expected_provenance.get("builderIdentity"):
            raise ManifestError(f"provenance builder identity differs for variant {variant!r}")
        _text(
            actual_provenance.get("attestationId"),
            f"manifest.images[{variant!r}].provenance.attestationId",
        )
        provenance_subject = _digest(
            actual_provenance.get("subjectDigest"),
            f"manifest.images[{variant!r}].provenance.subjectDigest",
        )
        sbom = actual.get("sbom")
        if not isinstance(sbom, dict):
            raise ManifestError(f"sbom must be an object for variant {variant!r}")
        if sbom.get("predicateType") != "https://spdx.dev/Document":
            raise ManifestError(f"sbom predicate differs for variant {variant!r}")
        if sbom.get("ociSubject") != f"{repository}@{actual['indexDigest']}":
            raise ManifestError(f"sbom OCI subject differs for variant {variant!r}")
        sbom_subject = _digest(sbom.get("subjectDigest"), f"manifest.images[{variant!r}].sbom.subjectDigest")
        if provenance_subject != actual["indexDigest"] or sbom_subject != actual["indexDigest"]:
            raise ManifestError(f"attestations name a different subject for variant {variant!r}")

        base_variant = expected.get("baseVariant")
        if base_variant is not None:
            if not isinstance(base_variant, str) or base_variant not in actual_images:
                raise ManifestError(f"unknown base variant for {variant!r}")
            binding = actual.get("base")
            if not isinstance(binding, dict) or binding != {
                "variant": base_variant,
                "digest": actual_images[base_variant].get("indexDigest"),
            }:
                raise ManifestError(f"derived variant {variant!r} is not bound to same-run base digest")

        expected_platforms = _index_unique(
            _objects(expected.get("platforms"), f"config.images[{variant!r}].platforms"),
            f"config.images[{variant!r}].platforms",
            _platform_identity,
        )
        actual_platforms = _index_unique(
            _objects(actual.get("platforms"), f"manifest.images[{variant!r}].platforms"),
            f"manifest.images[{variant!r}].platforms",
            _platform_identity,
        )
        if actual_platforms.keys() != expected_platforms.keys():
            raise ManifestError(
                f"platform matrix differs for variant {variant!r}"
            )
        for identity, platform in actual_platforms.items():
            _digest(platform.get("digest"), f"manifest.images[{variant!r}].platforms[{identity!r}].digest")


def _load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise ManifestError(f"{path} must contain a JSON object")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate a release manifest against reviewed consumer identity"
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args()
    try:
        validate_manifest(_load(args.manifest), _load(args.config))
    except ManifestError as error:
        print(f"container release manifest rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
