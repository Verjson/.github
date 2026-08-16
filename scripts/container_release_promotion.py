#!/usr/bin/env python3

import argparse
import json
import re
import sys
from pathlib import Path

from container_release_manifest import ManifestError, validate_manifest


SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def load(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ManifestError(f"{path} must contain an object")
    return value


def release(candidate: dict, config: dict, state: dict, version: str) -> dict:
    validate_manifest(candidate, config)
    if not SEMVER.fullmatch(version) or version != config.get("nextStableVersion"):
        raise ManifestError("release version must be the reviewed next stable SemVer")
    if state.get("gitTag") or state.get("changelogSnapshot") or state.get("githubRelease"):
        raise ManifestError("stable Git, changelog, or GitHub Release identity already exists")
    aliases = state.get("aliases", {})
    candidate_digest = state.get("candidateManifestDigest")
    if not isinstance(candidate_digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", candidate_digest):
        raise ManifestError("candidate manifest must be bound to an immutable digest")
    if not isinstance(aliases, dict):
        raise ManifestError("registry alias state must be an object")
    release_context = state.get("release")
    timestamps = state.get("timestamps")
    provenance = state.get("provenance")
    sbom_receipts = state.get("sbom")
    if not isinstance(release_context, dict) or not isinstance(timestamps, dict) or not isinstance(provenance, dict) or not isinstance(sbom_receipts, dict):
        raise ManifestError("release identity, timestamps, and verified provenance are required")
    if not re.fullmatch(r"[0-9a-f]{40}", str(release_context.get("sourceCommit", ""))):
        raise ManifestError("release source commit must be a 40-hex commit")
    previous = state.get("previousRelease")
    if previous is not None:
        if not isinstance(previous, dict) or not SEMVER.fullmatch(str(previous.get("releaseVersion", ""))):
            raise ManifestError("previous release identity is invalid")
        if tuple(map(int, previous["releaseVersion"].split("."))) >= tuple(map(int, version.split("."))):
            raise ManifestError("release version must advance the stable line")

    images = []
    operations = []
    for image in sorted(candidate["images"], key=lambda item: item["variant"]):
        repository, digest = image["repository"], image["indexDigest"]
        alias = f"{repository}:{version}"
        observed = aliases.get(alias)
        if observed not in (None, digest):
            raise ManifestError(f"stable alias {alias} names a different digest")
        operations.append({"alias": alias, "digest": digest})
        attestation_digest = provenance.get(image["variant"])
        if not isinstance(attestation_digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", attestation_digest):
            raise ManifestError(f"verified provenance receipt missing for variant {image['variant']!r}")
        sbom_digest = sbom_receipts.get(image["variant"])
        if not isinstance(sbom_digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", sbom_digest):
            raise ManifestError(f"verified SBOM receipt missing for variant {image['variant']!r}")
        images.append({
            "variant": image["variant"], "repository": repository,
            "indexDigest": digest, "platforms": image["platforms"],
            "provenance": {"predicateType": image["provenance"]["predicateType"], "attestationDigest": attestation_digest, "builderIdentity": image["provenance"]["builderIdentity"]},
            "sbom": {"predicateType": image["sbom"]["predicateType"], "attestationDigest": sbom_digest},
        })
    workflow, contract = candidate["source"]["workflow"].rsplit("@", 1)
    path_prefix = "Verjson/.github/"
    if not workflow.startswith(path_prefix):
        raise ManifestError("candidate workflow is outside the contract repository")
    return {
        "schemaVersion": 2,
        "releaseVersion": version,
        "candidateVersion": candidate["candidateVersion"],
        "candidateManifestDigest": candidate_digest,
        "source": {"repository": candidate["source"]["repository"], "commit": candidate["source"]["commit"], "workflow": {"path": workflow[len(path_prefix):], "contractCommit": contract}, "runId": int(candidate["source"]["runId"]), "runAttempt": int(candidate["source"]["runAttempt"])},
        "release": release_context,
        "images": images,
        "previousRelease": previous,
        "timestamps": timestamps,
        "promotion": {
            "operationOrder": [item["alias"] for item in operations],
            "operations": operations,
            "recovery": "retry only after every existing alias resolves to its recorded digest; divergent aliases require operator quarantine",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = release(load(args.candidate), load(args.config), load(args.state), args.version)
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except (OSError, json.JSONDecodeError, ManifestError) as error:
        print(f"container release rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
