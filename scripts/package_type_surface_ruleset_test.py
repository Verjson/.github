#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("package_type_surface_ruleset", ROOT / "scripts/package-type-surface-ruleset.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PackageTypeSurfaceRulesetTest(unittest.TestCase):
    def test_policy_requires_only_release_authorization(self):
        _, _, entries = MODULE.read_policy()
        expected = [{"actor_type": "Integration", "actor_id": 4583107, "bypass_mode": "always"}]
        self.assertTrue(entries)
        for entry in entries:
            self.assertEqual(entry["desired"]["bypass_actors"], expected)

    def test_policy_rejects_an_extra_desired_actor(self):
        document = json.loads((ROOT / "config/package-type-surface-rulesets.json").read_text())
        document["rulesets"][0]["desired"]["bypass_actors"].append({"actor_type": "OrganizationAdmin", "actor_id": None, "bypass_mode": "always"})
        with tempfile.NamedTemporaryFile("w", suffix=".json") as stream:
            json.dump(document, stream)
            stream.flush()
            with self.assertRaises(MODULE.ContractError):
                MODULE.read_policy(Path(stream.name))

    def test_validate_live_rejects_a_missing_release_actor(self):
        _, _, entries = MODULE.read_policy()
        entry = entries[0]
        live = {"id": entry["ruleset_id"], "name": entry["name"], "source_type": "Repository", "source": entry["repository"], **entry["desired"]}
        live["bypass_actors"] = []
        with self.assertRaises(MODULE.ContractError):
            MODULE.validate_live("Verjson", entry, live, entry["desired"])

    def test_validate_live_rejects_an_unexpected_source(self):
        _, _, entries = MODULE.read_policy()
        entry = entries[0]
        live = {"id": entry["ruleset_id"], "name": entry["name"], "source_type": "Organization", "source": "Verjson", **entry["desired"]}
        with self.assertRaises(MODULE.ContractError):
            MODULE.validate_live("Verjson", entry, live, entry["desired"])


if __name__ == "__main__":
    unittest.main()
