import copy
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
AUDIT = ROOT / "scripts/org-ruleset-conformance.py"
POLICY = ROOT / "config/org-ruleset-conformance-policy.json"


def ruleset(
    ruleset_id,
    *,
    name=None,
    target="branch",
    include=None,
    bypass_actors=None,
    rules=None,
):
    return {
        "id": ruleset_id,
        "name": name or f"ruleset-{ruleset_id}",
        "source_type": "Organization",
        "target": target,
        "enforcement": "active",
        "bypass_actors": bypass_actors
        if bypass_actors is not None
        else [
            {"actor_type": "OrganizationAdmin", "actor_id": None, "bypass_mode": "always"},
            {"actor_type": "Integration", "actor_id": 4583107, "bypass_mode": "always"},
        ],
        "conditions": {
            "ref_name": {"include": include or ["~DEFAULT_BRANCH"], "exclude": []},
            "repository_property": {
                "include": [{"name": "verjson-core-checks", "property_values": ["enforced"]}],
                "exclude": [],
            },
        },
        "rules": rules
        if rules is not None
        else [{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": False}}],
    }


class OrgRulesetConformanceTest(unittest.TestCase):
    def run_audit(
        self,
        pages,
        details,
        *,
        failing_paths=None,
        raw_policy=None,
        use_test_policy=True,
        inherited_policy=None,
        extra_arguments=None,
    ):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            policy = temp / "policy.json"
            policy.write_text(
                raw_policy
                if raw_policy is not None
                else json.dumps(
                    {
                        "organization": "Verjson",
                        "release_authorization_bypass": {
                            "actor_type": "Integration",
                            "actor_id": 4583107,
                            "bypass_mode": "always",
                        },
                        "bypassless_required_workflows": [],
                    }
                ),
                encoding="utf-8",
            )
            calls = temp / "calls.jsonl"
            gh = temp / "gh"
            gh.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "args = sys.argv[1:]\n"
                "with open(os.environ['CALLS'], 'a', encoding='utf-8') as stream:\n"
                "    stream.write(json.dumps(args) + '\\n')\n"
                "expected = ['api', '--hostname', 'github.com', '--method', 'GET', '--paginate', '--slurp']\n"
                "if args[:-1] != expected:\n"
                "    print('unexpected gh arguments', file=sys.stderr); sys.exit(90)\n"
                "path = args[-1]\n"
                "if path in json.loads(os.environ['FAILING_PATHS']):\n"
                "    print('simulated HTTP failure', file=sys.stderr); sys.exit(1)\n"
                "responses = json.loads(os.environ['RESPONSES'])\n"
                "if path not in responses:\n"
                "    print('unexpected API path', file=sys.stderr); sys.exit(91)\n"
                "print(json.dumps(responses[path]))\n",
                encoding="utf-8",
            )
            gh.chmod(0o755)
            responses = {"orgs/Verjson/rulesets?per_page=100": pages}
            responses.update(
                {f"orgs/Verjson/rulesets/{ruleset_id}": [detail] for ruleset_id, detail in details.items()}
            )
            env = os.environ | {
                "PATH": f"{temp}:{os.environ['PATH']}",
                "RESPONSES": json.dumps(responses),
                "FAILING_PATHS": json.dumps(failing_paths or []),
                "CALLS": str(calls),
            }
            env.pop("ORG_RULESET_POLICY", None)
            if inherited_policy is not None:
                inherited = temp / "inherited-policy.json"
                inherited.write_text(json.dumps(inherited_policy), encoding="utf-8")
                env["ORG_RULESET_POLICY"] = str(inherited)
            command = ["python3", str(AUDIT)]
            if use_test_policy:
                command.extend(["--test-policy", str(policy)])
            command.extend(extra_arguments or [])
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            recorded = []
            if calls.exists():
                recorded = [json.loads(line) for line in calls.read_text(encoding="utf-8").splitlines()]
            return result, recorded

    def test_preserves_existing_actors_rules_and_conditions_while_accepting_required_actor(self):
        detail = ruleset(
            1,
            bypass_actors=[
                {"actor_type": "OrganizationAdmin", "actor_id": None, "bypass_mode": "always"},
                {"actor_type": "Integration", "actor_id": 2740, "bypass_mode": "always"},
                {"actor_type": "Integration", "actor_id": 4583107, "bypass_mode": "always"},
            ],
            rules=[
                {"type": "deletion"},
                {"type": "pull_request", "parameters": {"required_approving_review_count": 1}},
                {"type": "workflows", "parameters": {"workflows": [{"path": ".github/workflows/gate-rearm.yml"}]}},
            ],
        )
        original = copy.deepcopy(detail)

        result, calls = self.run_audit([[{"id": 1}]], {1: detail})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rulesets=1 default_branch_token_rulesets=1", result.stdout)
        self.assertEqual(detail, original)
        self.assertEqual(
            calls,
            [
                ["api", "--hostname", "github.com", "--method", "GET", "--paginate", "--slurp", "orgs/Verjson/rulesets?per_page=100"],
                ["api", "--hostname", "github.com", "--method", "GET", "--paginate", "--slurp", "orgs/Verjson/rulesets/1"],
            ],
        )
        self.assertNotIn("required_approving_review_count", result.stdout + result.stderr)

    def test_committed_policy_pins_the_release_authorization_app(self):
        self.assertEqual(
            json.loads(POLICY.read_text(encoding="utf-8")),
            {
                "organization": "Verjson",
                "release_authorization_bypass": {
                    "actor_type": "Integration",
                    "actor_id": 4583107,
                    "bypass_mode": "always",
                },
                "bypassless_required_workflows": [
                    {
                        "name": "authn-type-surface-required-workflow",
                        "repository_id": 1302124584,
                        "workflow_repository_id": 1269388380,
                        "workflow_path": ".github/workflows/authn-type-surface-required.yml",
                        "workflow_ref": "refs/heads/main",
                    }
                ],
            },
        )

    def test_inherited_policy_environment_cannot_redirect_production_policy(self):
        detail = ruleset(13)
        result, calls = self.run_audit(
            [[{"id": 13}]],
            {13: detail},
            use_test_policy=False,
            inherited_policy={
                "organization": "Attacker",
                "release_authorization_bypass": {
                    "actor_type": "Integration",
                    "actor_id": 1,
                    "bypass_mode": "always",
                },
                "bypassless_required_workflows": [],
            },
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("organization=Verjson", result.stdout)
        self.assertTrue(
            all(call[-1].startswith("orgs/Verjson/rulesets") for call in calls),
            calls,
        )

    def test_only_the_explicit_test_policy_argument_is_accepted(self):
        result, _ = self.run_audit(
            [[{"id": 14}]],
            {14: ruleset(14)},
            use_test_policy=False,
            extra_arguments=["--policy", "/tmp/untrusted.json"],
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("usage: org-ruleset-conformance.py [--test-policy PATH]", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_current_core_checks_actions_shape_without_release_actor_fails(self):
        detail = ruleset(
            20515822,
            name="core-checks-actions",
            bypass_actors=[
                {"actor_type": "OrganizationAdmin", "actor_id": None, "bypass_mode": "always"}
            ],
        )

        result, _ = self.run_audit([[{"id": 20515822}]], {20515822: detail})

        self.assertEqual(result.returncode, 1)
        self.assertIn("core-checks-actions (20515822)", result.stderr)
        self.assertIn("required release authorization bypass is absent", result.stderr)

    def test_exact_authn_required_workflow_is_the_only_bypassless_exception(self):
        detail = ruleset(
            99,
            name="authn-type-surface-required-workflow",
            bypass_actors=[],
            rules=[{
                "type": "workflows",
                "parameters": {
                    "do_not_enforce_on_create": False,
                    "workflows": [{
                        "path": ".github/workflows/authn-type-surface-required.yml",
                        "repository_id": 1269388380,
                        "ref": "refs/heads/main",
                        "sha": "a" * 40,
                    }],
                },
            }],
        )
        detail["conditions"] = {
            "ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []},
            "repository_id": {"repository_ids": [1302124584]},
        }
        policy = POLICY.read_text(encoding="utf-8")
        result, _ = self.run_audit(
            [[{"id": 99}]], {99: detail}, raw_policy=policy
        )
        self.assertEqual(0, result.returncode, result.stderr)

        for mutation in ("repository", "path", "sha", "bypass"):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(detail)
                if mutation == "repository":
                    changed["conditions"]["repository_id"]["repository_ids"] = [1]
                elif mutation == "path":
                    changed["rules"][0]["parameters"]["workflows"][0]["path"] = ".github/workflows/ci.yml"
                elif mutation == "sha":
                    changed["rules"][0]["parameters"]["workflows"][0]["sha"] = "main"
                else:
                    changed["bypass_actors"] = [{
                        "actor_type": "OrganizationAdmin",
                        "actor_id": None,
                        "bypass_mode": "always",
                    }]
                result, _ = self.run_audit(
                    [[{"id": 99}]], {99: changed}, raw_policy=policy
                )
                self.assertEqual(1, result.returncode)
                self.assertIn("required release authorization bypass is absent", result.stderr)

    def test_wrong_actor_type_id_or_mode_does_not_satisfy_policy(self):
        wrong_actors = [
            {"actor_type": "Team", "actor_id": 4583107, "bypass_mode": "always"},
            {"actor_type": "Integration", "actor_id": 4583108, "bypass_mode": "always"},
            {"actor_type": "Integration", "actor_id": 4583107, "bypass_mode": "pull_request"},
        ]
        for actor in wrong_actors:
            with self.subTest(actor=actor):
                detail = ruleset(2, bypass_actors=[actor])
                result, _ = self.run_audit([[{"id": 2}]], {2: detail})
                self.assertEqual(result.returncode, 1)
                self.assertIn("required release authorization bypass is absent", result.stderr)

    def test_only_literal_default_branch_token_on_branch_target_requires_actor(self):
        develop_only = ruleset(3, include=["refs/heads/develop"], bypass_actors=[])
        tag_target = ruleset(4, target="tag", bypass_actors=[])
        all_branches = ruleset(15, include=["~ALL"], bypass_actors=[])
        explicit_main = ruleset(16, include=["refs/heads/main"], bypass_actors=[])

        result, _ = self.run_audit(
            [[{"id": 3}, {"id": 4}, {"id": 15}, {"id": 16}]],
            {3: develop_only, 4: tag_target, 15: all_branches, 16: explicit_main},
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rulesets=4 default_branch_token_rulesets=0", result.stdout)

    def test_paginated_listing_is_fully_enumerated(self):
        first = ruleset(5)
        second = ruleset(6, name="second-page", bypass_actors=[])

        result, calls = self.run_audit([[{"id": 5}], [{"id": 6}]], {5: first, 6: second})

        self.assertEqual(result.returncode, 1)
        self.assertIn("second-page (6)", result.stderr)
        self.assertEqual(len(calls), 3)

    def test_listing_and_detail_http_failures_fail_closed(self):
        listing_path = "orgs/Verjson/rulesets?per_page=100"
        result, _ = self.run_audit([], {}, failing_paths=[listing_path])
        self.assertEqual(result.returncode, 2)
        self.assertIn("GitHub API read failed", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

        detail_path = "orgs/Verjson/rulesets/7"
        result, _ = self.run_audit(
            [[{"id": 7}]], {7: ruleset(7)}, failing_paths=[detail_path]
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("GitHub API read failed", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_malformed_or_incomplete_api_shapes_fail_closed(self):
        cases = [
            ([], {}, "GitHub API returned no pages"),
            ([[]], {}, "ruleset listing contained no rulesets"),
            ([[{"name": "missing-id"}]], {}, "ruleset listing entry 0 on page 0.id"),
            ([[{"id": 8}]], {8: {"id": 8}}, "ruleset 8.name"),
            (
                [[{"id": 9}]],
                {9: ruleset(9) | {"rules": ["not-an-object"]}},
                "ruleset 9 rule 0 must be an object",
            ),
            (
                [[{"id": 10}]],
                {10: ruleset(10) | {"conditions": {"ref_name": {"include": "~DEFAULT_BRANCH", "exclude": []}}}},
                "ruleset 10.conditions.ref_name.include must be an array",
            ),
        ]
        for pages, details, diagnostic in cases:
            with self.subTest(diagnostic=diagnostic):
                result, _ = self.run_audit(pages, details)
                self.assertEqual(result.returncode, 2)
                self.assertIn(diagnostic, result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_duplicate_policy_keys_and_duplicate_ruleset_ids_fail_closed(self):
        result, _ = self.run_audit(
            [[{"id": 11}]],
            {11: ruleset(11)},
            raw_policy=(
                '{"organization":"Verjson","release_authorization_bypass":'
                '{"actor_type":"Integration","actor_id":4583107,'
                '"actor_id":1,"bypass_mode":"always"}}'
            ),
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("duplicate object key 'actor_id'", result.stderr)

        result, _ = self.run_audit([[{"id": 12}], [{"id": 12}]], {12: ruleset(12)})
        self.assertEqual(result.returncode, 2)
        self.assertIn("duplicate ruleset id 12", result.stderr)


if __name__ == "__main__":
    unittest.main()
