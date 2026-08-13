#!/usr/bin/env python3
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(__file__).with_name("prepare-deepseek-replay.py")
spec = importlib.util.spec_from_file_location("prepare_deepseek_replay", SCRIPT)
replay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay)
verdict_spec = importlib.util.spec_from_file_location("review_verdict", Path(__file__).with_name("review-verdict.py"))
review_verdict = importlib.util.module_from_spec(verdict_spec)
verdict_spec.loader.exec_module(review_verdict)
HEAD = "a" * 40
MODEL = "deepseek-v4-pro"


def bundle() -> dict:
    return {
        "schema": 1, "purpose": "diagnostic-replay", "authorizing": False,
        "cacheable": False, "transport": "completed",
        "provenance": {
            "reviewed_head": HEAD, "authorization_check_id": "9001",
            "repository": "Verjson/.github", "pr_number": 7, "review_pass": 1, "sensitive": False,
            "review_policy_sha256": "b" * 64, "prompt_sha256": "c" * 64,
            "pr_metadata_sha256": "d" * 64, "pr_diff_sha256": "e" * 64,
        },
        "response": {
            "model": MODEL,
            "usage": {"prompt_tokens": 10, "completion_tokens": 5, "cache_hit_tokens": 2, "cache_miss_tokens": 8},
            "verdict": {"blocking": True, "summary": "bad evidence", "review_first": [], "findings": [{
                "location": "app.py:1", "reason": "broken", "failure_scenario": "fails", "evidence": "wrong source"
            }], "followups": []},
            "bounds": {"input_token_bound": 100, "max_output_tokens": 65536, "reported_cost_usd": "0.01"},
        },
    }


class DeepSeekReplayTest(unittest.TestCase):
    def run_prepare(self, transport="success", usable="false", publication="success", diagnostic=None):
        temp = tempfile.TemporaryDirectory()
        root = Path(temp.name)
        source, output = root / "source.json", root / "output.json"
        source.write_text(json.dumps(bundle()), encoding="utf-8")
        diagnostic = diagnostic or json.dumps({
            "path": "findings[0].evidence", "expected": "exact-head source fragment", "observed": "fragment mismatch"
        })
        available = replay.prepare(
            source, output, transport, usable, publication, diagnostic, HEAD, "9001", MODEL,
            "Verjson/.github", 7, 1, False,
        )
        return temp, output, available

    def test_source_evidence_rejection_is_staged_as_non_authorizing_replay(self):
        reviewed_head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        candidate = bundle()
        candidate["provenance"]["reviewed_head"] = reviewed_head
        verdict = candidate["response"]["verdict"]
        verdict["findings"][0]["location"] = ".github/workflows/ai-review-merge.yml:1"
        result = review_verdict.confirm_output(json.dumps(verdict), False, str(ROOT), reviewed_head)
        self.assertFalse(result["usable"])
        self.assertEqual(result["diagnostic"]["observed"], "fragment mismatch")
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        source, output = root / "source.json", root / "output.json"
        source.write_text(json.dumps(candidate), encoding="utf-8")
        available = replay.prepare(
            source, output, "success", "false", "success",
            json.dumps(result["diagnostic"]), reviewed_head, "9001", MODEL,
            "Verjson/.github", 7, 1, False,
        )
        staged = json.loads(output.read_text())
        self.assertTrue(available)
        self.assertEqual(staged["failure"]["phase"], "canonical-validation")
        self.assertEqual(staged["failure"]["diagnostic"]["observed"], "fragment mismatch")
        self.assertFalse(staged["authorizing"])
        self.assertFalse(staged["cacheable"])
        self.assertEqual(staged["provenance"]["reviewed_head"], reviewed_head)
        replayed = review_verdict.confirm_output(
            json.dumps(staged["response"]["verdict"]),
            staged["provenance"]["sensitive"],
            str(ROOT),
            staged["provenance"]["reviewed_head"],
        )
        self.assertFalse(replayed["usable"])
        self.assertEqual(replayed["diagnostic"], staged["failure"]["diagnostic"])

    def test_success_and_incomplete_transport_never_stage_artifacts(self):
        temp, output, available = self.run_prepare(usable="true", publication="success")
        self.addCleanup(temp.cleanup)
        self.assertFalse(available)
        self.assertFalse(output.exists())

        temp, output, available = self.run_prepare(transport="failure")
        self.addCleanup(temp.cleanup)
        self.assertFalse(available)
        self.assertFalse(output.exists())

    def test_publication_failure_stages_completed_usable_verdict(self):
        temp, output, available = self.run_prepare(usable="true", publication="failure")
        self.addCleanup(temp.cleanup)
        self.assertTrue(available)
        self.assertEqual(json.loads(output.read_text())["failure"], {
            "phase": "publication", "diagnostic": "publication step failed"
        })

    def test_provenance_mutation_and_sensitive_unknown_fields_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "source", root / "output"
            candidate = bundle()
            candidate["provenance"]["prompt_sha256"] = "sensitive prompt"
            source.write_text(json.dumps(candidate), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "provenance"):
                replay.prepare(source, output, "success", "false", "success", "{}", HEAD, "9001", MODEL,
                               "Verjson/.github", 7, 1, False)

    def test_authorization_check_substitution_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "source", root / "output"
            source.write_text(json.dumps(bundle()), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "provenance"):
                replay.prepare(source, output, "success", "false", "success", "{}", HEAD, "9002", MODEL,
                               "Verjson/.github", 7, 1, False)

    def test_workflow_upload_is_failure_only_best_effort_and_short_lived(self):
        workflow = (ROOT / ".github/workflows/ai-review-merge.yml").read_text()
        self.assertEqual(workflow.count("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1"), 3)
        for step_id in ("replay_primary", "replay_fallback"):
            self.assertIn(f"if: always() && steps.{step_id}.outputs.available == 'true'", workflow)
        self.assertEqual(workflow.count("retention-days: 1"), 2)
        self.assertIn("PUBLICATION: ${{ steps.submit.conclusion }}", workflow)
        self.assertEqual(workflow.count('REVIEW_PASS: "1"'), 2)
        self.assertEqual(workflow.count('REVIEW_PASS: "2"'), 2)
        self.assertEqual(workflow.count("SENSITIVE: ${{ needs.preflight.outputs.sensitive }}"), 6)
        for argument in (
            "--expected-check-id", "--expected-repository", "--expected-pr",
            "--expected-pass", "--expected-sensitive",
        ):
            self.assertEqual(workflow.count(argument), 2)
        self.assertNotIn("download-artifact", workflow)


if __name__ == "__main__":
    unittest.main()
