#!/usr/bin/env python3

import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any, Callable, Sequence

from container_release_manifest import validate_manifest


RunCommand = Callable[..., subprocess.CompletedProcess[str]]


def _write_json(path: Path, value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    path.write_text(encoded, encoding="utf-8")
    return "sha256:" + hashlib.sha256(encoded.encode()).hexdigest()


def _verify(
    subject: str,
    predicate_type: str,
    source: dict[str, Any],
    *,
    bundle_from_oci: bool,
    run: RunCommand,
) -> Any:
    workflow, signer_digest = source["workflow"].rsplit("@", 1)
    command = ["gh", "attestation", "verify", subject, "--repo", source["repository"]]
    if bundle_from_oci:
        command.append("--bundle-from-oci")
    command.extend(
        [
            "--predicate-type",
            predicate_type,
            "--signer-workflow",
            workflow,
            "--signer-digest",
            signer_digest,
            "--source-ref",
            source["ref"],
            "--source-digest",
            source["commit"],
            "--format",
            "json",
        ]
    )
    completed = run(command, check=True, text=True, stdout=subprocess.PIPE)
    return json.loads(completed.stdout)


def verify(
    candidate: dict[str, Any],
    config: dict[str, Any],
    receipt_directory: Path,
    *,
    run: RunCommand = subprocess.run,
) -> dict[str, dict[str, str]]:
    validate_manifest(candidate, config)
    receipt_directory.mkdir(parents=True, exist_ok=True)
    source = candidate["source"]
    receipt_digests: dict[str, dict[str, str]] = {"provenance": {}, "sbom": {}}

    for image in sorted(candidate["images"], key=lambda value: value["variant"]):
        variant = image["variant"]
        repository = image["repository"]
        provenance = _verify(
            f"oci://{repository}@{image['indexDigest']}",
            image["provenance"]["predicateType"],
            source,
            bundle_from_oci=False,
            run=run,
        )
        receipt_digests["provenance"][variant] = _write_json(
            receipt_directory / f"{variant}-provenance.json", provenance
        )

        sbom_receipts = []
        for attestation in sorted(
            image["sbom"]["attestations"],
            key=lambda value: (
                value["os"],
                value["architecture"],
                value.get("variant", ""),
            ),
        ):
            sbom_receipts.append(
                _verify(
                    f"oci://{repository}@{attestation['digest']}",
                    image["sbom"]["predicateType"],
                    source,
                    bundle_from_oci=True,
                    run=run,
                )
            )
        receipt_digests["sbom"][variant] = _write_json(
            receipt_directory / f"{variant}-sbom.json", sbom_receipts
        )

    return receipt_digests


def _load(path: Path) -> Any:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--receipts", type=Path, required=True)
    args = parser.parse_args(argv)

    state = _load(args.state)
    state.update(verify(_load(args.candidate), _load(args.config), args.receipts))
    temporary = args.state.with_suffix(args.state.suffix + ".next")
    _write_json(temporary, state)
    temporary.replace(args.state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
