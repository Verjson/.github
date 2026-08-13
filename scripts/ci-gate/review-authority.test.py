#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[2]
gate = (root / ".github/workflows/ai-review-merge.yml").read_text()
arm = (root / ".github/workflows/gate-rearm.yml").read_text()
policy = (root / "scripts/ci-gate/review-policy-envelope.py").read_text()
promotion = (root / ".github/workflows/ai-privileged-merge.yml").read_text()
retry = (root / ".github/workflows/ai-promotion-retry.yml").read_text()


def contract(candidate_gate=gate, candidate_arm=arm, candidate_policy=policy):
    checks = {
        "human authority is the safe default": "REVIEW_AUTHORITY: ${{ vars.AI_REVIEW_AUTHORITY || 'human' }}" in candidate_arm,
        "authority enum is validated before dispatch": 'case "$authority" in human|ai-approve|ai-merge)' in candidate_arm,
        "authority is receipt-bound": "--arg authority \"$authority\"" in candidate_arm and '"authority"' in candidate_policy,
        "code and agent instructions require AI": "REVIEW_CLASSIFIER" in candidate_gate and "code change — human approval path" not in candidate_gate,
        "post-open opt-in bypasses same-head deduplication": "explicit_ai_review=true" in candidate_arm and '[ "$explicit_rereview" = false ] && [ "$explicit_ai_review" = false ]' in candidate_arm,
        "human fallback remains available": "Human approval remains available" in candidate_gate,
        "cumulative review cap is enforced before model spend": "Reserve cumulative AI review pass 1" in candidate_gate and 'if [ "$consumed" -ge 2 ]' in candidate_gate,
        "blocking verdict is advisory": "AI review advisory: blocking verdict" in candidate_gate and "outcome=blocking" in candidate_gate,
        "inconclusive verdict is advisory": "outcome=inconclusive" in candidate_gate and "Human approval remains available" in candidate_gate,
        "AI review never requests changes": "--request-changes" not in candidate_gate,
        "App approval requires explicit authority": '[ "$REVIEW_OUTCOME" = approved ] && { [ "$REVIEW_AUTHORITY" = ai-approve ] || [ "$REVIEW_AUTHORITY" = ai-merge ]; }' in candidate_gate,
        "terminal merge requires ai-merge": "needs.preflight.outputs.authority == 'ai-merge'" in candidate_gate and "outputs.ai_authorized == 'true'" in candidate_gate,
        "ai-approve cannot reach terminal merge": "needs.preflight.outputs.authority == 'ai-approve'" not in candidate_gate.split("  dispatch-merge:", 1)[1],
        "DeepSeek order is fixed": "deepseek-v4-pro then deepseek-v4-flash" in candidate_arm,
        "fallback runs only without pass-one verdict": "steps.verdict_1.outputs.usable != 'true'" in candidate_gate,
        "fallback is separately budgeted": "fallback_budget_usd" in candidate_gate and "PRIMARY_FALLBACK_BUDGET_USD" in candidate_arm,
        "DeepSeek credential stays step-scoped": "DEEPSEEK_API_KEY: ${{ secrets.DEEPSEEK_API_KEY }}" in candidate_gate,
    }
    return [name for name, okay in checks.items() if not okay]


assert not contract(), contract()

mutations = {
    "default AI authority": (gate, arm.replace("AI_REVIEW_AUTHORITY || 'human'", "AI_REVIEW_AUTHORITY || 'ai-merge'"), policy),
    "unconditional App approval": (gate.replace('[ "$REVIEW_OUTCOME" = approved ] && { [ "$REVIEW_AUTHORITY" = ai-approve ] || [ "$REVIEW_AUTHORITY" = ai-merge ]; }', '[ "$REVIEW_OUTCOME" = approved ]'), arm, policy),
    "merge on ai-approve": (gate.replace("needs.preflight.outputs.authority == 'ai-merge'", "needs.preflight.outputs.authority == 'ai-approve'"), arm, policy),
    "fallback after usable verdict": (gate.replace("steps.verdict_1.outputs.usable != 'true'", "steps.verdict_1.outputs.usable == 'true'"), arm, policy),
    "deduplicated post-open opt-in": (gate, arm.replace('[ "$explicit_rereview" = false ] && [ "$explicit_ai_review" = false ]', '[ "$explicit_rereview" = false ]'), policy),
    "third review admitted": (gate.replace('if [ "$consumed" -ge 2 ]', 'if [ "$consumed" -ge 3 ]'), arm, policy),
    "blocking review state": (gate.replace("gh pr comment \"$PR_NUMBER\"", "gh pr review \"$PR_NUMBER\" --request-changes", 1), arm, policy),
}
for name, surfaces in mutations.items():
    assert contract(*surfaces), f"mutation escaped authority contract: {name}"

downstream_guards = (
    'review-policy-envelope.py decode "$REVIEW_POLICY"',
    '[ "$(jq -r \'.authority // "human"\' <<<"$policy_json")" = ai-merge ]',
)
def downstream_contract(candidate_promotion=promotion, candidate_retry=retry):
    return (
        all(guard in candidate_promotion for guard in downstream_guards)
        and 'review-policy-envelope.py decode "$review_policy"' in candidate_retry
        and '!= ai-merge' in candidate_retry
    )


assert downstream_contract()
assert not downstream_contract(promotion.replace(downstream_guards[1], "true", 1), retry)
assert not downstream_contract(promotion, retry.replace('!= ai-merge', '= ai-merge', 1))

print("PASS: human fallback, mandatory code review, AI authority, and the cumulative two-pass cap are contract-bound")
