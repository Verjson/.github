#!/usr/bin/env python3
import base64
import json
import subprocess
from pathlib import Path

tool = Path(__file__).with_name("review-policy-envelope.py")
policy = {
    "actor": "maintainer;$(touch /tmp/not-executed)",
    "actor_permission": "maintain",
    "authority": "ai-merge",
    "budget_usd": "5.00",
    "fallback_budget_usd": "5.00",
    "fallback_model": "deepseek-v4-flash",
    "model": "deepseek-v4-pro",
    "pricing_version": "deepseek-v4-2026-08-10",
    "provider": "deepseek",
}
canonical = json.dumps(policy, sort_keys=True, separators=(",", ":"))


def run(mode, value):
    return subprocess.run(["python3", str(tool), mode, value], text=True, capture_output=True)


encoded = run("encode", canonical)
assert encoded.returncode == 0, encoded.stderr
envelope = encoded.stdout.strip()
decoded = run("decode", envelope)
assert decoded.returncode == 0 and decoded.stdout.strip() == canonical
assert "deepseek-v4-pro" in decoded.stdout and "ai-merge" in decoded.stdout

legacy = {key: policy[key] for key in ("actor", "actor_permission", "budget_usd", "model", "pricing_version", "provider")}
legacy_canonical = json.dumps(legacy, sort_keys=True, separators=(",", ":"))
legacy_encoded = run("encode", legacy_canonical)
assert legacy_encoded.returncode == 0
assert run("decode", legacy_encoded.stdout.strip()).stdout.strip() == legacy_canonical

mutations = {
    "quote stripping": canonical.replace('"', ""),
    "key reordering": json.dumps(dict(reversed(tuple(policy.items()))), separators=(",", ":")),
    "whitespace": json.dumps(policy, sort_keys=True),
    "duplicate keys": canonical[:-1] + ',"provider":"deepseek"}',
    "extra field": canonical[:-1] + ',"extra":"x"}',
    "missing field": json.dumps({k: v for k, v in policy.items() if k != "model"}, sort_keys=True, separators=(",", ":")),
}
for name, raw in mutations.items():
    candidate = base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")
    result = run("decode", candidate)
    assert result.returncode != 0, f"accepted {name}"

for name, candidate in {
    "invalid alphabet": envelope + "+",
    "explicit padding": envelope + "=",
    "oversized": "A" * 2049,
}.items():
    assert run("decode", candidate).returncode != 0, f"accepted {name}"

assert not Path("/tmp/not-executed").exists(), "shell metacharacters executed"
print("PASS: canonical policy envelope rejects all boundary mutations")
