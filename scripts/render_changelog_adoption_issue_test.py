import importlib.util
import unittest
from pathlib import Path

PATH = Path(__file__).with_name("render-changelog-adoption-issue.py")
SPEC = importlib.util.spec_from_file_location("render_changelog_adoption_issue", PATH)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class AdoptionIssueTest(unittest.TestCase):
    def test_render_uses_machine_readable_recommendation_and_current_context(self):
        text = module.render("Verjson/example", Path(__file__).parents[1])
        self.assertIn("413bf03b179ff3028e6c7da5551aaa44562ddd8d", text)
        self.assertIn("gen-changelog-caller.sh pr-gate", text)
        self.assertIn("`changelog / validate`", text)
        self.assertIn("obsolete `generated-artifacts / validate`", text)
        self.assertNotIn("23f641822d1fdf4787a46f0b55f24a755b8a73ae", text)

    def test_malformed_repository_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "OWNER/NAME"):
            module.render("Verjson/example/escape", Path(__file__).parents[1])


if __name__ == "__main__":
    unittest.main()
