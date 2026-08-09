#!/usr/bin/env python3
import base64
import json
import subprocess
from pathlib import Path

tool = Path(__file__).with_name("review-policy-envelope.py")
policy = {
    "actor": "maintainer;$(touch /tmp/not-executed)",
    "actor_permission": "maintain",
    "budget_usd": "1.00",
    "model": "gpt-5.6-luna",
    "pricing_version": "openai-luna-long-context-2026-08-08",
    "provider": "openai",
}
canonical = json.dumps(policy, sort_keys=True, separators=(",", ":"))


def run(mode, value):
    return subprocess.run(["python3", str(tool), mode, value], text=True, capture_output=True)


encoded = run("encode", canonical)
assert encoded.returncode == 0, encoded.stderr
envelope = encoded.stdout.strip()
decoded = run("decode", envelope)
assert decoded.returncode == 0 and decoded.stdout.strip() == canonical
assert "gpt-5.6-luna" in decoded.stdout and "1.00" in decoded.stdout

mutations = {
    "quote stripping": canonical.replace('"', ""),
    "key reordering": json.dumps(dict(reversed(tuple(policy.items()))), separators=(",", ":")),
    "whitespace": json.dumps(policy, sort_keys=True),
    "duplicate keys": canonical[:-1] + ',"provider":"openai"}',
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
