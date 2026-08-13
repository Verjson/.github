#!/usr/bin/env python3
import argparse
import json
import re
import sys


PASS_MARKER = re.compile(
    r"<!-- ai-review-pass:v2:([12])/2 pr:([1-9][0-9]*) check:([1-9][0-9]*) "
    r"head:([0-9a-f]{40}) run:([1-9][0-9]*) attempt:([1-9][0-9]*) "
    r"provider:([a-z0-9_-]+) model:([A-Za-z0-9._-]+) -->"
)
EXPLICIT_MARKER = re.compile(
    r"<!-- ai-review-explicit:v1 pr:([1-9][0-9]*) check:([1-9][0-9]*) "
    r"head:([0-9a-f]{40}) run:([1-9][0-9]*) attempt:([1-9][0-9]*) "
    r"provider:([a-z0-9_-]+) model:([A-Za-z0-9._-]+) -->"
)


def count_attempts(reviews: object, app_login: str, pr_number: int) -> int:
    if not isinstance(reviews, list):
        raise ValueError("reviews payload must be an array")
    reservations: set[tuple[str, str, str, str]] = set()
    for review in reviews:
        if not isinstance(review, dict):
            raise ValueError("each review must be an object")
        user = review.get("user")
        body = review.get("body")
        commit_id = review.get("commit_id")
        state = review.get("state")
        if not isinstance(user, dict) or not isinstance(body, str):
            raise ValueError("each review requires user and body")
        if user.get("login") != app_login or state != "COMMENTED":
            continue
        for marker in PASS_MARKER.finditer(body):
            ordinal, marker_pr, _, head, run_id, run_attempt, _, _ = marker.groups()
            if int(marker_pr) != pr_number or commit_id != head:
                continue
            reservations.add(("automatic", run_id, run_attempt, ordinal))
        for marker in EXPLICIT_MARKER.finditer(body):
            marker_pr, _, head, run_id, run_attempt, _, _ = marker.groups()
            if int(marker_pr) != pr_number or commit_id != head:
                continue
            reservations.add(("explicit", run_id, run_attempt, "1"))
    return len(reservations)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-login", required=True)
    parser.add_argument("--pr-number", required=True, type=int)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*\[bot\]", args.app_login):
        parser.error("App login is malformed")
    if args.pr_number < 1:
        parser.error("PR number must be positive")
    try:
        reviews = json.load(sys.stdin)
        print(count_attempts(reviews, args.app_login, args.pr_number))
    except (json.JSONDecodeError, OSError, TypeError, ValueError) as error:
        print(f"review attempt accounting failed closed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
