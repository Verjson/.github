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
    def test_every_provider_output_path_uses_the_same_canonical_confirmation(self):
        text = json.dumps(VARIANT)
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
                    "content": [{"type": "output_text", "text": text}],
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
                    "message": {"role": "assistant", "content": text},
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
            "claude-workflow": text,
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
            {json.dumps(confirmations["claude-workflow"]["verdict"], sort_keys=True)},
        )


if __name__ == "__main__":
    unittest.main()
