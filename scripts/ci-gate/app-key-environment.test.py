#!/usr/bin/env python3
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("app_key_audit", ROOT / "scripts/app-key-environment-audit.py")
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


def workflow(name):
    return yaml.safe_load((ROOT / f".github/workflows/{name}.yml").read_text())


def metadata():
    result = {"repos/Verjson/example": [{"default_branch": "main", "owner": {"type": "Organization"}}],
              "repos/Verjson/example/actions/secrets?per_page=100": [{"total_count": 0, "secrets": []}],
              "orgs/Verjson/actions/secrets?per_page=100": [{"total_count": 0, "secrets": []}]}
    for role, key in audit.ROLES.items():
        path = f"repos/Verjson/example/environments/{role}-app"
        result[path] = [{"id": 42, "name": f"{role}-app", "deployment_branch_policy": {
            "protected_branches": False, "custom_branch_policies": True}}]
        result[path + "/deployment-branch-policies?per_page=100"] = [{"total_count": 1, "branch_policies": [{"name": "main", "type": "branch"}]}]
        result[path + "/secrets?per_page=100"] = [{"total_count": 1, "secrets": [{"name": key}]}]
    return result


class StorageAuditTests(unittest.TestCase):
    def test_environment_only_keys_with_exact_main_policies_are_compliant(self):
        self.assertTrue(audit.audit("Verjson/example", metadata().__getitem__)["compliant"])

    def test_broad_copies_fail_even_when_environment_copies_exist(self):
        for scope, path in (("broadRepositoryKeys", "repos/Verjson/example/actions/secrets?per_page=100"),
                            ("broadOrganizationKeys", "orgs/Verjson/actions/secrets?per_page=100")):
            with self.subTest(scope=scope):
                data = metadata()
                data[path] = [{"total_count": 1, "secrets": [{"name": "RELEASE_APP_PRIVATE_KEY"}]}]
                result = audit.audit("Verjson/example", data.__getitem__)
                self.assertFalse(result["compliant"])
                self.assertEqual(result[scope], ["RELEASE_APP_PRIVATE_KEY"])

    def test_missing_environment_key_fails_without_accepting_a_broad_fallback(self):
        data = metadata()
        data["repos/Verjson/example/environments/merge-app/secrets?per_page=100"] = [{"total_count": 0, "secrets": []}]
        self.assertFalse(audit.audit("Verjson/example", data.__getitem__)["compliant"])

    def test_branch_wildcards_tags_additional_refs_and_missing_types_are_rejected(self):
        for policies in ([{"name": "*", "type": "branch"}], [{"name": "main", "type": "tag"}],
                         [{"name": "main"}], [{"name": "main", "type": "branch"}, {"name": "release/*", "type": "branch"}]):
            with self.subTest(policies=policies):
                data = metadata()
                data["repos/Verjson/example/environments/release-app/deployment-branch-policies?per_page=100"] = [{"total_count": len(policies), "branch_policies": policies}]
                with self.assertRaises(ValueError):
                    audit.audit("Verjson/example", data.__getitem__)

    def test_protected_branches_only_is_not_main_only(self):
        data = metadata()
        data["repos/Verjson/example/environments/release-app"][0]["deployment_branch_policy"] = {"protected_branches": True, "custom_branch_policies": False}
        with self.assertRaises(ValueError):
            audit.audit("Verjson/example", data.__getitem__)

    def test_unreadable_metadata_and_incomplete_pagination_never_prove_absence(self):
        with self.assertRaises(subprocess.CalledProcessError):
            audit.audit("Verjson/example", mock.Mock(side_effect=subprocess.CalledProcessError(1, "gh")))
        for pages in ([{"total_count": 1, "secrets": []}], [{"total_count": 2, "secrets": [{"name": "X"}, {"name": "X"}]}]):
            with self.subTest(pages=pages), self.assertRaises(ValueError):
                audit.names(pages, "secrets")

    def test_malformed_environment_identity_and_boolean_metadata_are_rejected(self):
        path = "repos/Verjson/example/environments/release-app"
        for identity in (None, 0, -1, True, "42"):
            with self.subTest(identity=identity):
                data = metadata()
                data[path][0]["id"] = identity
                with self.assertRaises(ValueError):
                    audit.audit("Verjson/example", data.__getitem__)
        for field, value in (("protected_branches", 0), ("custom_branch_policies", 1)):
            with self.subTest(field=field):
                data = metadata()
                data[path][0]["deployment_branch_policy"][field] = value
                with self.assertRaises(ValueError):
                    audit.audit("Verjson/example", data.__getitem__)
        for count in (None, False, "0"):
            with self.subTest(count=count), self.assertRaises(ValueError):
                audit.names([{"total_count": count, "secrets": []}], "secrets")

    def test_inventory_collects_every_page_and_never_fetches_secret_values(self):
        pages = [{"total_count": 2, "secrets": [{"name": "X"}]}, {"total_count": 2, "secrets": [{"name": "Y"}]}]
        self.assertEqual(audit.names(pages, "secrets"), {"X", "Y"})
        with mock.patch.object(audit.subprocess, "run", return_value=mock.Mock(stdout=json.dumps(pages))) as run:
            self.assertEqual(audit.github("repos/Verjson/example/actions/secrets?per_page=100"), pages)
        self.assertEqual(run.call_args.args[0][:4], ["gh", "api", "--paginate", "--slurp"])


class WorkflowBoundaryTests(unittest.TestCase):
    def test_key_consumers_declare_required_environment_and_depend_on_keyless_policy(self):
        consumers = {
            "changelog-release": ("release_environment", ["release"]),
            "container-release": ("release_environment", ["promote"]),
            "renovate-changelog": ("release_environment", ["attribute"]),
            "ai-privileged-merge": ("merge_environment", ["privileged_merge"]),
            "ai-review-merge": ("ai_review_environment", ["gate", "complete-authorization"]),
            "gate-rearm": ("ai_review_environment", ["arm"]),
        }
        for name, (field, jobs) in consumers.items():
            with self.subTest(name=name):
                doc = workflow(name)
                trigger = doc.get("on", doc.get(True))
                self.assertTrue(trigger["workflow_call"]["inputs"][field]["required"])
                self.assertFalse(set(trigger["workflow_call"].get("secrets", {})) & (set(audit.ROLES.values()) | {"release_app_private_key"}))
                policy = doc["jobs"]["app-key-policy"]
                self.assertEqual(policy["uses"], "./.github/workflows/app-key-environment.yml")
                self.assertNotIn("secrets", policy)
                for job in jobs:
                    value = doc["jobs"][job]
                    self.assertIn(field, value["environment"])
                    self.assertIn("app-key-policy", value["needs"])
                    if "always()" in value.get("if", ""):
                        self.assertIn("needs.app-key-policy.result == 'success'", value["if"])

    def test_retry_inherits_context_and_retains_fixed_environment(self):
        retry = workflow("ai-promotion-retry")
        self.assertTrue(retry[True]["workflow_call"]["inputs"]["merge_environment"]["required"])
        self.assertEqual(retry["jobs"]["promote"]["secrets"], "inherit")
        self.assertIn("merge_environment", retry["jobs"]["promote"]["with"])
        self.assertNotIn("release_app_private_key", workflow("node-release")[True]["workflow_call"].get("secrets", {}))

    def test_retry_chain_and_native_callers_preserve_inheritance_at_every_edge(self):
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        generated = subprocess.check_output(["bash", str(ROOT / "scripts/gen-privileged-merge-caller.sh"), sha,
            "--retry", '["CI"]', '[{"name":"CI","app_id":1,"workflow_id":2,"workflow_path":".github/workflows/ci.yml"}]'], text=True)
        retry = yaml.safe_load(generated)["jobs"]["retry"]
        self.assertEqual(retry["uses"], f"Verjson/.github/.github/workflows/ai-promotion-retry.yml@{sha}")
        self.assertEqual(retry["secrets"], "inherit")
        self.assertEqual(retry["with"]["merge_environment"], "merge-app")
        for name, job, target, field in [
                ("ai-promotion-retry", "promote", "ai-privileged-merge", "merge_environment"),
                ("ai-review-label-rearm", "rearm", "gate-rearm", "ai_review_environment"),
                ("container-release-workflow-ref-canary", "probe", "container-release", "release_environment")]:
            with self.subTest(name=name):
                edge = workflow(name)["jobs"][job]
                self.assertEqual(edge["uses"], f"./.github/workflows/{target}.yml")
                self.assertEqual(edge["secrets"], "inherit")
                self.assertIn(field, edge["with"])

    def test_inheritance_preserves_actual_model_names_and_narrow_node_publication(self):
        review = workflow("ai-review-merge")
        names = {"ANTHROPIC_API_KEY", "OPENAI_API_KEY", "DEEPSEEK_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"}
        self.assertEqual(set(review[True]["workflow_call"]["secrets"]), names)
        source = (ROOT / ".github/workflows/ai-review-merge.yml").read_text()
        for name in names:
            self.assertIn("${{ secrets." + name + " }}", source)
            self.assertNotIn("${{ secrets." + name.lower() + " }}", source)
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        generated = subprocess.check_output(["bash", str(ROOT / "scripts/gen-changelog-caller.sh"), "release-node", sha], text=True)
        jobs = yaml.safe_load(generated)["jobs"]
        publishing = next(job for job in jobs.values() if "node-release.yml@" in job.get("uses", ""))
        self.assertEqual(publishing["secrets"], {"NODE_AUTH_TOKEN": "${{ secrets.NODE_AUTH_TOKEN }}"})
        snapshot = next(job for job in jobs.values() if "changelog-release.yml@" in job.get("uses", ""))
        self.assertEqual(snapshot["secrets"], "inherit")

    def test_body_only_edits_allocate_neither_policy_nor_key_job(self):
        jobs = workflow("gate-rearm")["jobs"]
        guard = "github.event.action != 'edited' || github.event.changes.title.from"
        self.assertEqual(jobs["app-key-policy"]["if"], guard)
        self.assertIn(guard, jobs["arm"]["if"])

    def test_native_rearm_and_retry_defaults_are_only_canonical_role_environments(self):
        rearm = workflow("gate-rearm")["jobs"]
        expression = "${{ inputs.ai_review_environment || 'ai-review-app' }}"
        self.assertEqual(rearm["app-key-policy"]["with"]["environment"], expression)
        self.assertEqual(rearm["arm"]["environment"], expression)
        self.assertEqual(workflow("ai-promotion-retry")["jobs"]["promote"]["with"]["merge_environment"],
                         "${{ inputs.merge_environment || 'merge-app' }}")

    def test_generators_emit_environment_names_with_inherited_context_without_key_values(self):
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        cases = [(["gen-ai-review-caller.sh", sha], "ai_review_environment"),
                 (["gen-gate-rearm-caller.sh", sha], "ai_review_environment"),
                 (["gen-ai-review-label-rearm-caller.sh", sha], "ai_review_environment"),
                 (["gen-privileged-merge-caller.sh", sha, '[{"name":"CI","app_id":1,"workflow_id":2,"workflow_path":".github/workflows/ci.yml"}]'], "merge_environment"),
                 (["gen-container-release.sh", "workflow", sha], "release_environment"),
                 (["gen-changelog-caller.sh", "release-node", sha], "release_environment"),
                 (["gen-changelog-caller.sh", "release-snapshot", sha], "release_environment"),
                 (["gen-changelog-caller.sh", "renovate-attribution", sha], "release_environment")]
        for command, field in cases:
            with self.subTest(command=command[0:2]):
                text = subprocess.check_output(["bash", str(ROOT / "scripts" / command[0]), *command[1:]], cwd=ROOT, text=True)
                doc = yaml.safe_load(text)
                self.assertNotIn("PRIVATE_KEY", text)
                self.assertIn("secrets: inherit", text)
                consumers = [j for j in doc["jobs"].values() if field in j.get("with", {})]
                self.assertTrue(consumers)
                self.assertTrue(all("environment" not in j for j in consumers))
                self.assertTrue(all(j.get("secrets") == "inherit" for j in consumers))

    def test_lint_exception_is_exact_to_the_environment_secret_schema_gap(self):
        config = yaml.safe_load((ROOT / ".github/actionlint.yaml").read_text())
        patterns = config["paths"][".github/workflows/ai-review-merge.yml"]["ignore"]
        selected = [p for p in patterns if "ai_review_app_private_key" in p]
        self.assertEqual(len(selected), 1)
        message = 'property "ai_review_app_private_key" is not defined in object type {actions_runner_debug: string; actions_step_debug: string; anthropic_api_key: string; claude_code_oauth_token: string; deepseek_api_key: string; github_token: string; openai_api_key: string}'
        self.assertIsNotNone(re.fullmatch(selected[0], message))
        self.assertIsNone(re.fullmatch(selected[0], message.replace("ai_review_app_private_key", "unexpected_private_key")))

    def test_policy_validation_has_no_key_environment_or_checkout(self):
        doc = workflow("app-key-environment")
        self.assertEqual(doc["permissions"], {"actions": "read", "contents": "read"})
        job = doc["jobs"]["validate"]
        self.assertNotIn("environment", job)
        self.assertNotIn("secrets", str(job))
        self.assertNotIn("actions/checkout", str(job))

    def run_policy(self, *, ref="refs/heads/main", name="release-app", role="release", policy=None, unavailable=False):
        step = workflow("app-key-environment")["jobs"]["validate"]["steps"][0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh = root / "gh"
            gh.write_text('#!/usr/bin/env python3\nimport json,os,sys\nif os.environ.get("UNAVAILABLE")=="1":sys.exit(1)\nif "deployment-branch-policies" in sys.argv[-1]:print(os.environ["POLICY"])\nelse:print(json.dumps({"id":42,"name":os.environ["ENVIRONMENT"],"deployment_branch_policy":{"protected_branches":False,"custom_branch_policies":True}}))\n')
            gh.chmod(0o755)
            result = subprocess.run(["bash", "-c", step["run"]], text=True, capture_output=True,
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "REF": ref, "DEFAULT_BRANCH": "main",
                     "ROLE": role, "ENVIRONMENT": name, "REPOSITORY": "Verjson/example", "UNAVAILABLE": "1" if unavailable else "0",
                     "POLICY": json.dumps(policy or {"total_count": 1, "branch_policies": [{"name": "main", "type": "branch"}]})})
            return result.returncode

    def test_native_policy_preflight_accepts_only_main_and_exact_role(self):
        self.assertEqual(self.run_policy(), 0)
        for kwargs in ({"ref": "refs/heads/topic"}, {"ref": "refs/tags/main"}, {"name": "unguarded"}, {"role": "unknown"}, {"unavailable": True},
                       {"policy": {"total_count": 1, "branch_policies": [{"name": "*", "type": "branch"}]}},
                       {"policy": {"total_count": 1, "branch_policies": [{"name": "main", "type": "tag"}]}}):
            with self.subTest(kwargs=kwargs):
                self.assertNotEqual(self.run_policy(**kwargs), 0)


if __name__ == "__main__":
    unittest.main()
