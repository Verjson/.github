#!/usr/bin/env python3
import copy
import importlib.util
import json
import unittest
from pathlib import Path
from unittest import mock

PATH = Path(__file__).parents[1] / "dependency-supersession.py"
SPEC = importlib.util.spec_from_file_location("dependency_supersession", PATH)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)

BASE = "1" * 40
OLD = "2" * 40
NEW = "3" * 40


def pr(number, head, login="renovate[bot]", state="open", labels=None):
    return {"number": number, "state": state, "draft": False, "labels": labels or [],
            "base": {"sha": BASE, "ref": "main"}, "head": {"sha": head, "ref": f"bot/{number}"},
            "user": {"login": login, "type": "Bot", "id": 29139614}}


class Api:
    def __init__(self):
        self.prs = {1: pr(1, OLD), 2: pr(2, NEW)}
        self.versions = {OLD: "1.1.0", NEW: "1.2.0"}
        self.writes = []

    def __call__(self, path, method="GET", fields=None):
        if path == "repos/Verjson/demo":
            return {"full_name": "Verjson/demo", "default_branch": "main"}
        if path == "repos/Verjson/demo/pulls?state=open&per_page=100":
            return [{"number": n} for n, value in self.prs.items() if value["state"] == "open"]
        match = module.re.fullmatch(r"repos/Verjson/demo/pulls/(\d+)", path)
        if match:
            number = int(match.group(1))
            if method == "PATCH":
                self.prs[number]["state"] = fields["state"]
                self.writes.append((method, path))
                return self.prs[number]
            return copy.deepcopy(self.prs[number])
        match = module.re.fullmatch(r"repos/Verjson/demo/pulls/(\d+)/commits\?per_page=100", path)
        if match:
            actor = self.prs[int(match.group(1))]["user"]
            return [{"author": copy.deepcopy(actor)}]
        match = module.re.fullmatch(r"repos/Verjson/demo/pulls/(\d+)/files\?per_page=100", path)
        if match:
            head = self.prs[int(match.group(1))]["head"]["sha"]
            return [{"filename": "package.json", "sha": "b" + head[1:], "status": "modified"},
                    {"filename": "pnpm-lock.yaml", "sha": "c" + head[1:], "status": "modified"}]
        match = module.re.fullmatch(r"repos/Verjson/demo/contents/package.json\?ref=([0-9a-f]{40})", path)
        if match:
            import base64
            ref = match.group(1)
            value = "1.0.0" if ref == BASE else self.versions[ref]
            raw = json.dumps({"dependencies": {"dep": value}}).encode()
            sha = "a" * 40 if ref == BASE else "b" + ref[1:]
            return {"encoding": "base64", "content": base64.b64encode(raw).decode(), "sha": sha}
        if path == "repos/Verjson/demo/issues/1/comments?per_page=100":
            return []
        if path == "repos/Verjson/demo/issues/1/comments" and method == "POST":
            self.writes.append((method, path))
            return {"id": 1}
        if path == "repos/Verjson/demo/issues/1/events?per_page=100":
            return [{"event": "closed", "actor": {"login": "canonical-dependency-supersession[bot]"}}]
        raise AssertionError((method, path, fields))


class SupersessionTest(unittest.TestCase):
    def observe(self, api=None):
        api = api or Api()
        with mock.patch.object(module, "gh", side_effect=api):
            return module.observe("Verjson/demo"), api

    def test_observer_emits_exact_group_coverage_and_no_writes(self):
        proposal, api = self.observe()
        self.assertEqual(len(proposal["proposals"]), 1)
        item = proposal["proposals"][0]
        self.assertEqual(item["candidate"]["headSha"], OLD)
        self.assertEqual(item["replacement"]["headSha"], NEW)
        self.assertRegex(item["receipt"], r"^[0-9a-f]{64}$")
        self.assertEqual(api.writes, [])

    def test_partial_group_overlap_is_report_only(self):
        candidate = {"baseRef": "main", "baseSha": BASE, "transitions": [
            {"ecosystem": "npm", "manifest": "package.json", "section": "dependencies", "name": "a", "from": "1.0.0", "to": "1.1.0"},
            {"ecosystem": "npm", "manifest": "package.json", "section": "dependencies", "name": "b", "from": "1.0.0", "to": "1.1.0"}]}
        replacement = copy.deepcopy(candidate)
        replacement["transitions"] = replacement["transitions"][:1]
        self.assertFalse(module.covers(candidate, replacement))

    def test_downgrade_unknown_version_and_prerelease_ambiguity_fail_closed(self):
        for old, new in (("2.0.0", "1.0.0"), ("workspace:*", "1.0.0")):
            api = Api()
            api.versions[OLD], api.versions[NEW] = old, new
            proposal, _ = self.observe(api)
            self.assertEqual(proposal["proposals"], [])
        a = {"baseRef": "main", "baseSha": BASE, "transitions": [{"ecosystem": "npm", "manifest": "package.json", "section": "dependencies", "name": "a", "from": "1.0.0", "to": "2.0.0-alpha"}]}
        b = copy.deepcopy(a); b["transitions"][0]["to"] = "2.0.0-beta"
        with self.assertRaisesRegex(module.Refusal, "prerelease"):
            module.covers(a, b)

    def test_range_operator_changes_are_ambiguous(self):
        api = Api()
        api.versions[OLD], api.versions[NEW] = "^1.1.0", "~1.2.0"
        proposal, _ = self.observe(api)
        self.assertEqual(proposal["proposals"], [])

    def test_human_manual_mixed_and_security_exception_are_refused(self):
        for mutate in (
            lambda api: api.prs[1].update(user={"login": "human", "type": "User", "id": 4}),
            lambda api: api.prs[1].update(labels=[{"name": "security-exception"}]),
        ):
            api = Api(); mutate(api)
            proposal, _ = self.observe(api)
            self.assertEqual(proposal["proposals"], [])

    def test_malformed_truncated_and_mixed_files_fail_closed(self):
        api = Api()
        original = api.__call__
        def malformed(path, method="GET", fields=None):
            if path.endswith("/pulls/1/files?per_page=100"):
                return [{"filename": "src/index.js", "sha": "a" * 40, "status": "modified"}]
            return original(path, method, fields)
        with mock.patch.object(module, "gh", side_effect=malformed):
            proposal = module.observe("Verjson/demo")
        self.assertEqual(proposal["proposals"], [])

    def test_reconcile_refetches_and_observe_mode_never_writes(self):
        proposal, api = self.observe()
        receipt = proposal["proposals"][0]["receipt"]
        with mock.patch.object(module, "gh", side_effect=api):
            result = module.reconcile(proposal, receipt, False)
        self.assertEqual(result["writes"], [])
        self.assertEqual(api.writes, [])

    def test_stale_head_and_malformed_receipt_fail_before_writes(self):
        proposal, api = self.observe()
        receipt = proposal["proposals"][0]["receipt"]
        api.prs[1]["head"]["sha"] = "4" * 40
        api.versions["4" * 40] = "1.1.0"
        with mock.patch.object(module, "gh", side_effect=api):
            with self.assertRaisesRegex(module.Refusal, "live state"):
                module.reconcile(proposal, receipt, True)
        self.assertEqual(api.writes, [])
        with self.assertRaisesRegex(module.Refusal, "envelope"):
            module.reconcile(proposal, "not-a-receipt", False)

    def test_enforcement_comments_before_close(self):
        proposal, api = self.observe()
        receipt = proposal["proposals"][0]["receipt"]
        with mock.patch.object(module, "gh", side_effect=api):
            result = module.reconcile(proposal, receipt, True)
        self.assertEqual(result["writes"], ["comment", "close"])
        self.assertEqual(api.writes, [("POST", "repos/Verjson/demo/issues/1/comments"), ("PATCH", "repos/Verjson/demo/pulls/1")])


if __name__ == "__main__":
    unittest.main()
