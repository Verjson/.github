#!/usr/bin/env python3

import argparse
import json
import sys
from pathlib import Path
from typing import Any


class ManifestError(ValueError):
    pass


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
    source = manifest.get("source")
    if not isinstance(source, dict):
        raise ManifestError("manifest.source must be an object")
    expected_repository = _text(config.get("repository"), "config.repository")
    if source.get("repository") != expected_repository:
        raise ManifestError("manifest source repository differs from reviewed config")

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

        expected_provenance = expected.get("provenance")
        actual_provenance = actual.get("provenance")
        if not isinstance(expected_provenance, dict) or not isinstance(actual_provenance, dict):
            raise ManifestError(f"provenance must be an object for variant {variant!r}")
        for key in ("predicateType", "builderIdentity"):
            if actual_provenance.get(key) != expected_provenance.get(key):
                raise ManifestError(
                    f"provenance {key} differs for variant {variant!r}"
                )

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
