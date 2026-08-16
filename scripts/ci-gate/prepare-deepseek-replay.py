#!/usr/bin/env python3
"""Stage a completed DeepSeek replay only after downstream failure."""

import argparse
import json
import re
from pathlib import Path

MAX_REPLAY_BYTES = 1024 * 1024
MAX_DIAGNOSTIC_BYTES = 16 * 1024
MAX_RESPONSE_CONTENT_BYTES = 65536 * 1024
EXTRACTION_KINDS = {
    "json_decode", "response_shape", "usage_envelope", "tool_call", "verdict_shape",
}


def valid_provenance(provenance: object, expected_head: str, expected_check_id: str,
                     expected_repository: str, expected_pr: int, expected_pass: int,
                     expected_sensitive: bool, expected_trusted_review_sha: str) -> bool:
    digest_fields = ("review_policy_sha256", "prompt_sha256", "pr_metadata_sha256", "pr_diff_sha256")
    return (
        isinstance(provenance, dict)
        and set(provenance) == {
            "reviewed_head", "authorization_check_id", "repository", "pr_number",
            "review_pass", "sensitive", "trusted_review_sha", *digest_fields,
        }
        and provenance.get("reviewed_head") == expected_head
        and re.fullmatch(r"[0-9a-f]{40}", expected_head) is not None
        and re.fullmatch(r"[1-9][0-9]*", expected_check_id) is not None
        and provenance.get("authorization_check_id") == expected_check_id
        and provenance.get("repository") == expected_repository
        and provenance.get("pr_number") == expected_pr
        and provenance.get("review_pass") == expected_pass
        and provenance.get("sensitive") is expected_sensitive
        and re.fullmatch(r"[0-9a-f]{40}", expected_trusted_review_sha) is not None
        and provenance.get("trusted_review_sha") == expected_trusted_review_sha
        and all(re.fullmatch(r"[0-9a-f]{64}", provenance.get(field, "")) for field in digest_fields)
    )


def valid_extraction_failure(failure: object) -> bool:
    if not isinstance(failure, dict):
        return False
    kind = failure.get("kind")
    expected_fields = {"stage", "kind", "content_bytes", "content_sha256"}
    if kind == "json_decode":
        expected_fields.add("json_error")
    if (
        set(failure) != expected_fields
        or failure.get("stage") != "completed_response_extraction"
        or kind not in EXTRACTION_KINDS
        or type(failure.get("content_bytes")) is not int
        or not 0 <= failure["content_bytes"] <= MAX_RESPONSE_CONTENT_BYTES
        or re.fullmatch(r"[0-9a-f]{64}", failure.get("content_sha256", "")) is None
    ):
        return False
    if kind != "json_decode":
        return True
    location = failure.get("json_error")
    return (
        isinstance(location, dict)
        and set(location) == {"line", "column", "position"}
        and type(location["line"]) is int and location["line"] >= 1
        and type(location["column"]) is int and location["column"] >= 1
        and type(location["position"]) is int and location["position"] >= 0
    )


def prepare(source: Path, output: Path, transport: str, usable: str, publication: str,
            diagnostic: str, expected_head: str, expected_check_id: str, expected_model: str,
            expected_repository: str, expected_pr: int, expected_pass: int, expected_sensitive: bool,
            expected_trusted_review_sha: str) -> bool:
    if not source.is_file():
        return False
    raw = source.read_bytes()
    if not raw or len(raw) > MAX_REPLAY_BYTES:
        raise ValueError("replay source is missing or oversized")
    bundle = json.loads(raw)
    provenance = bundle.get("provenance", {})
    if bundle.get("purpose") == "extraction-diagnostic":
        if (
            len(raw) > MAX_DIAGNOSTIC_BYTES
            or transport != "failure" or usable == "true"
            or set(bundle) != {
                "schema", "purpose", "authorizing", "cacheable", "transport",
                "model", "provenance", "failure",
            }
            or bundle["schema"] != 1 or bundle["authorizing"] is not False
            or bundle["cacheable"] is not False or bundle["transport"] != "completed"
            or bundle.get("model") != expected_model
            or not valid_provenance(
                provenance, expected_head, expected_check_id, expected_repository,
                expected_pr, expected_pass, expected_sensitive, expected_trusted_review_sha,
            )
            or not valid_extraction_failure(bundle.get("failure"))
        ):
            raise ValueError("extraction diagnostic violates its non-authorizing provenance contract")
        output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        output.write_bytes(raw if raw.endswith(b"\n") else raw + b"\n")
        return True
    if transport != "success" or (usable == "true" and publication != "failure"):
        return False
    response = bundle.get("response", {})
    usage = response.get("usage", {})
    bounds = response.get("bounds", {})
    if (
        set(bundle) != {"schema", "purpose", "authorizing", "cacheable", "transport", "provenance", "response"}
        or bundle["schema"] != 1 or bundle["purpose"] != "diagnostic-replay"
        or bundle["authorizing"] is not False or bundle["cacheable"] is not False
        or bundle["transport"] != "completed"
        or not valid_provenance(
            provenance, expected_head, expected_check_id, expected_repository,
            expected_pr, expected_pass, expected_sensitive, expected_trusted_review_sha,
        )
        or set(response) != {"model", "usage", "verdict", "bounds"}
        or response.get("model") != expected_model
        or set(usage) != {"prompt_tokens", "completion_tokens", "cache_hit_tokens", "cache_miss_tokens"}
        or any(type(value) is not int or value < 0 for value in usage.values())
        or set(bounds) != {"input_token_bound", "max_output_tokens", "reported_cost_usd"}
        or type(bounds.get("input_token_bound")) is not int or bounds["input_token_bound"] < 1
        or type(bounds.get("max_output_tokens")) is not int or bounds["max_output_tokens"] < 1
        or not isinstance(bounds.get("reported_cost_usd"), str)
        or not isinstance(response.get("verdict"), dict)
    ):
        raise ValueError("replay source violates its non-authorizing provenance contract")
    if usable != "true":
        parsed_diagnostic = json.loads(diagnostic)
        bundle["failure"] = {"phase": "canonical-validation", "diagnostic": parsed_diagnostic}
    else:
        bundle["failure"] = {"phase": "publication", "diagnostic": "publication step failed"}
    encoded = json.dumps(bundle, sort_keys=True, separators=(",", ":")).encode("utf-8")
    if len(encoded) > MAX_REPLAY_BYTES:
        raise ValueError("staged replay exceeds its bounded limit")
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    output.write_bytes(encoded + b"\n")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--transport", required=True)
    parser.add_argument("--usable", required=True)
    parser.add_argument("--publication", required=True)
    parser.add_argument("--diagnostic", default="{}")
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--expected-check-id", required=True)
    parser.add_argument("--expected-model", required=True)
    parser.add_argument("--expected-repository", required=True)
    parser.add_argument("--expected-pr", type=int, required=True)
    parser.add_argument("--expected-pass", type=int, required=True)
    parser.add_argument("--expected-sensitive", choices=("true", "false"), required=True)
    parser.add_argument("--expected-trusted-review-sha", required=True)
    parser.add_argument("--github-output", type=Path, required=True)
    args = parser.parse_args()
    available = prepare(args.source, args.output, args.transport, args.usable, args.publication,
                        args.diagnostic, args.expected_head, args.expected_check_id, args.expected_model,
                        args.expected_repository, args.expected_pr, args.expected_pass,
                        args.expected_sensitive == "true", args.expected_trusted_review_sha)
    with args.github_output.open("a", encoding="utf-8") as output:
        output.write(f"available={'true' if available else 'false'}\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError):
        raise SystemExit(1)
