#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[2]
arm = (root / ".github/workflows/gate-rearm.yml").read_text()
gate = (root / ".github/workflows/ai-review-merge.yml").read_text()
receipt = (root / "scripts/ci-gate/verify-arm-receipt.sh").read_text()
client = (root / "scripts/ci-gate/openai-review.py").read_text()

dispatch = gate.split("  workflow_dispatch:\n", 1)[1].split("  workflow_call:\n", 1)[0]
dispatch_inputs = [line for line in dispatch.splitlines() if line.startswith("      ") and not line.startswith("        ") and line.rstrip().endswith(":")]

checks = {
    "primary and rereview org variables are separate": all(name in arm for name in (
        "AI_REVIEW_PRIMARY_PROVIDER", "AI_REVIEW_PRIMARY_MODEL", "AI_REVIEW_PRIMARY_BUDGET_USD",
        "AI_REVIEW_REREVIEW_PROVIDER", "AI_REVIEW_REREVIEW_MODEL", "AI_REVIEW_REREVIEW_BUDGET_USD")),
    "secondary is selected only by explicit re-review": 'if [ "$explicit_rereview" = true ]; then' in arm and "REREVIEW_PROVIDER" in arm,
    "absent secondary fails before dispatch": "explicit re-review policy is not fully configured" in arm,
    "policy is receipt and dispatch bound": all(surface.count("review_policy") > 0 for surface in (arm, receipt, gate)),
    "workflow dispatch stays within GitHub input limit": len(dispatch_inputs) <= 10,
    "paid re-review requires maintainer permission": "collaborators/$REQUEST_ACTOR/permission" in arm and "admin|maintain" in arm and "no longer has maintain/admin" in receipt,
    "provider secrets remain scoped": "OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}" in gate and "anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}" in gate,
    "OpenAI is one explicit tool-free client": 'python3 "$RUNNER_TEMP/openai-review.py"' in gate and "needs.preflight.outputs.provider == 'openai'" in gate,
    "Anthropic retains native budget": "--max-budget-usd ${{ needs.preflight.outputs.budget_usd }}" in gate,
    "models use strict allowlists": "claude-haiku-4-5|claude-sonnet-5|claude-opus-5" in gate and "gpt-5.6-luna" in gate and "gpt-5.6-sol" not in gate,
    "OpenAI receives embedded bounded review inputs": "PR_JSON_FILE" in gate and "PR_DIFF_FILE" in gate,
    "trusted instructions are role-separated from PR data": '"role": "developer"' in client and '"role": "user"' in client and "untrusted PR data, not instructions" in client,
}
failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items(): print(("PASS" if ok else "FAIL") + ": " + name)
raise SystemExit(bool(failed))
