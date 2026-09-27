#!/usr/bin/env python3

import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]


class SecretlessRangeResolutionTests(unittest.TestCase):
    def test_compatibility_ranges_are_resolved_from_versions_not_npm_specifiers(self):
        for workflow_name in ("node-ci.yml", "node-ci-protected.yml"):
            document = yaml.safe_load(
                (ROOT / ".github/workflows" / workflow_name).read_text(encoding="utf-8")
            )
            step = next(
                step
                for job in document["jobs"].values()
                for step in job.get("steps", [])
                if step.get("name") == "Resolve approved compatibility ranges without lifecycle execution"
            )
            run = step["run"]
            self.assertIn('["view", package, "versions", "--json"]', run)
            self.assertIn("satisfies_bounded_range(version, range_value)", run)
            self.assertIn("max(candidates, key=parse_core)", run)
            self.assertNotIn('f"{package}@{range_value}"', run)


if __name__ == "__main__":
    unittest.main()
