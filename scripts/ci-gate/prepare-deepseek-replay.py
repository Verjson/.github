#!/usr/bin/env python3
"""Stage a completed DeepSeek replay only after downstream failure."""

import argparse
import json
import re
from pathlib import Path

MAX_REPLAY_BYTES = 1024 * 1024


def prepare(source: Path, output: Path, transport: str, usable: str, publication: str,
            diagnostic: str, expected_head: str, expected_check_id: str, expected_model: str,
            expected_repository: str, expected_pr: int, expected_pass: int, expected_sensitive: bool) -> bool:
    if transport != "success" or (usable == "true" and publication != "failure"):
        return False
    raw = source.read_bytes()
    if not raw or len(raw) > MAX_REPLAY_BYTES:
        raise ValueError("replay source is missing or oversized")
    bundle = json.loads(raw)
    provenance = bundle.get("provenance", {})
    response = bundle.get("response", {})
    usage = response.get("usage", {})
    bounds = response.get("bounds", {})
    digest_fields = ("review_policy_sha256", "prompt_sha256", "pr_metadata_sha256", "pr_diff_sha256")
    if (
        set(bundle) != {"schema", "purpose", "authorizing", "cacheable", "transport", "provenance", "response"}
        or bundle["schema"] != 1 or bundle["purpose"] != "diagnostic-replay"
        or bundle["authorizing"] is not False or bundle["cacheable"] is not False
        or bundle["transport"] != "completed"
        or set(provenance) != {
            "reviewed_head", "authorization_check_id", "repository", "pr_number",
            "review_pass", "sensitive", *digest_fields,
        }
        or provenance.get("reviewed_head") != expected_head
        or not re.fullmatch(r"[0-9a-f]{40}", expected_head)
        or not re.fullmatch(r"[1-9][0-9]*", expected_check_id)
        or provenance.get("authorization_check_id") != expected_check_id
        or provenance.get("repository") != expected_repository
        or provenance.get("pr_number") != expected_pr
        or provenance.get("review_pass") != expected_pass
        or provenance.get("sensitive") is not expected_sensitive
        or any(not re.fullmatch(r"[0-9a-f]{64}", provenance.get(field, "")) for field in digest_fields)
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
    parser.add_argument("--github-output", type=Path, required=True)
    args = parser.parse_args()
    available = prepare(args.source, args.output, args.transport, args.usable, args.publication,
                        args.diagnostic, args.expected_head, args.expected_check_id, args.expected_model,
                        args.expected_repository, args.expected_pr, args.expected_pass,
                        args.expected_sensitive == "true")
    with args.github_output.open("a", encoding="utf-8") as output:
        output.write(f"available={'true' if available else 'false'}\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError):
        raise SystemExit(1)
