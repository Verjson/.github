#!/usr/bin/env python3
import importlib.util
import json
import unittest
from pathlib import Path


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verdicts = load("review_verdict", "review-verdict.py")
openai = load("openai_review", "openai-review.py")
deepseek = load("deepseek_review", "deepseek-review.py")
WORKFLOW = Path(__file__).parents[2] / ".github/workflows/ai-review-merge.yml"


CANONICAL = {
    "blocking": False,
    "summary": "No defects found.",
    "review_first": [
        {
            "location": "scripts/ci-gate/review-verdict.py:42",
            "why": "Canonical trust boundary.",
        },
    ],
    "findings": [],
    "followups": [],
}


VARIANT = {
    "isBlocking": False,
    "summary": "No defects found.",
    "reviewFirst": [
        {
            "file": "scripts/ci-gate/review-verdict.py",
            "line": "42-48,55",
            "reason": "Canonical trust boundary.",
            "confidence": 0.98,
        },
    ],
    "findings": [],
    "followUps": [],
}


class ReviewProviderConformanceTest(unittest.TestCase):
    def test_provider_neutral_prompt_and_renderer_share_the_canonical_shape(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        prompt = workflow.split('echo "review_prompt<<PROMPT_EOF"', 1)[1].split('echo "PROMPT_EOF"', 1)[0]
        submit = workflow.split("      - name: Submit deterministic PR review", 1)[1]
        renderer = submit.split("body=$(jq -r '", 1)[1].split("' <<<\"$VERDICT\")", 1)[0]

        self.assertIn("review_first: [{location, why}]", prompt)
        self.assertIn("findings: [{location, reason, failure_scenario, evidence}]", prompt)
        self.assertIn("Every findings.location MUST contain exactly one repository-relative", prompt)
        self.assertIn("followups: [{location, note}]", prompt)
        self.assertIn(".review_first | map(\"- `\" + .location + \"` — \" + .why)", renderer)
        self.assertIn("(.evidence | @html)", renderer)
        self.assertIn("prompt: ${{ steps.prep.outputs.review_prompt }}", workflow)
        self.assertEqual(workflow.count("REVIEW_PROMPT: ${{ steps.prep.outputs.review_prompt }}"), 3)
        self.assertIn(
            "no ranges or comma-separated locations",
            openai.SCHEMA["properties"]["findings"]["items"]["properties"]["location"]["description"],
        )

    def test_every_provider_output_path_uses_the_same_canonical_confirmation(self):
        canonical_text = json.dumps(CANONICAL)
        deepseek_variant = json.dumps(VARIANT)
        openai_response = {
            "status": "completed",
            "model": openai.MODEL,
            "error": None,
            "incomplete_details": None,
            "usage": {"input_tokens": 1, "output_tokens": 20},
            "output": [
                {
                    "type": "message",
                    "status": "completed",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": canonical_text}],
                },
            ],
        }
        deepseek_response = {
            "object": "chat.completion",
            "model": "deepseek-v4-pro",
            "choices": [
                {
                    "index": 0,
                    "finish_reason": "stop",
                    "message": {"role": "assistant", "content": deepseek_variant},
                },
            ],
            "usage": {
                "prompt_tokens": 1,
                "completion_tokens": 20,
                "prompt_cache_hit_tokens": 0,
                "prompt_cache_miss_tokens": 1,
            },
        }
        provider_outputs = {
            "claude-workflow": canonical_text,
            "openai": openai.extract(openai_response, 100, 100, "5.00")[0],
            "deepseek": deepseek.extract(deepseek_response, "deepseek-v4-pro", 100, 100, "5.00")[0],
        }

        confirmations = {
            provider: verdicts.confirm_output(output, sensitive=True)
            for provider, output in provider_outputs.items()
        }

        self.assertTrue(all(result["usable"] for result in confirmations.values()))
        self.assertEqual(
            {json.dumps(result["verdict"], sort_keys=True) for result in confirmations.values()},
            {json.dumps(CANONICAL, sort_keys=True)},
        )

    def test_review_first_reason_and_rationale_remain_compatible_aliases(self):
        for alias in ("reason", "rationale"):
            variant = dict(CANONICAL)
            variant["review_first"] = [
                {
                    "location": "scripts/ci-gate/review-verdict.py:42",
                    alias: "Canonical trust boundary.",
                },
            ]

            with self.subTest(alias=alias):
                self.assertEqual(verdicts.canonicalize_verdict(variant, sensitive=True), CANONICAL)


if __name__ == "__main__":
    unittest.main()
