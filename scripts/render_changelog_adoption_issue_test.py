import importlib.util
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

PATH = Path(__file__).with_name("render-changelog-adoption-issue.py")
SPEC = importlib.util.spec_from_file_location("render_changelog_adoption_issue", PATH)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)

ROOT = Path(__file__).parents[1]
PIN = "413bf03b179ff3028e6c7da5551aaa44562ddd8d"
ARTIFACTS = (
    Path(".github/workflows/changelog.yml"),
    Path("scripts/render-next.sh"),
    Path("scripts/changelog-contract.test.sh"),
    Path(".github/workflows/changelog-contract.yml"),
)


def run(*args: str, cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, check=False)


def commit(root: Path, message: str) -> str:
    result = run(
        "git",
        "-c",
        "user.name=contract-test",
        "-c",
        "user.email=contract-test@example.invalid",
        "commit",
        "--allow-empty",
        "-m",
        message,
        cwd=root,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr)
    return run("git", "rev-parse", "HEAD", cwd=root).stdout.strip()


class AdoptionIssueTest(unittest.TestCase):
    def test_render_uses_machine_readable_recommendation_and_current_context(self):
        text = module.render("Verjson/example", ROOT)
        self.assertIn(PIN, text)
        self.assertIn("gen-changelog-caller.sh\" pr-gate", text)
        self.assertIn("`changelog / validate`", text)
        self.assertIn("obsolete `generated-artifacts / validate`", text)
        self.assertNotIn("23f641822d1fdf4787a46f0b55f24a755b8a73ae", text)

    def test_readme_literal_cannot_override_registry_or_admit_below_floor_pin(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp)
            initialized = run("git", "init", "-q", cwd=fixture)
            self.assertEqual(0, initialized.returncode, initialized.stderr)
            below_floor = commit(fixture, "below floor")
            floor = commit(fixture, "capability floor")
            recommendation = commit(fixture, "recommended contract")
            (fixture / "config").mkdir()
            (fixture / "docs/changelog").mkdir(parents=True)
            (fixture / "config/capability-floors.json").write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "recommended_pins": {module.CHANGELOG_GENERATOR: recommendation},
                        "capabilities": [
                            {
                                "id": "fixture-floor",
                                "introduced_at": floor,
                                "generators": [module.CHANGELOG_GENERATOR],
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            (fixture / "docs/changelog/README.md").write_text(
                f"<!-- recommended-contract-pin: {below_floor} -->\n",
                encoding="utf-8",
            )

            text = module.render("Verjson/example", fixture)

            self.assertIn(recommendation, text)
            self.assertNotIn(below_floor, text)
            registry = json.loads((fixture / "config/capability-floors.json").read_text(encoding="utf-8"))
            registry["recommended_pins"][module.CHANGELOG_GENERATOR] = below_floor
            (fixture / "config/capability-floors.json").write_text(json.dumps(registry), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "predates capability floor"):
                module.render("Verjson/example", fixture)

    def test_rendered_commands_generate_only_in_disposable_consumer(self):
        text = module.render("Verjson/example", ROOT)
        match = re.search(r"```bash\n(.*?)\n```", text, re.DOTALL)
        self.assertIsNotNone(match)

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            canonical = tmp_path / "canonical"
            consumer = tmp_path / "consumer"
            clone = run("git", "clone", "--quiet", str(ROOT), str(canonical), cwd=tmp_path)
            self.assertEqual(0, clone.returncode, clone.stderr)
            consumer.mkdir()
            initialized = run("git", "init", "-q", cwd=consumer)
            self.assertEqual(0, initialized.returncode, initialized.stderr)
            canonical_before = run("git", "status", "--porcelain=v1", cwd=canonical).stdout
            renderer_before = (canonical / "scripts/render-next.sh").read_bytes()
            env = os.environ.copy()
            env["CONTRACT_SOURCE_URL"] = str(canonical)

            result = run("bash", "-c", match.group(1), cwd=consumer, env=env)

            self.assertEqual(0, result.returncode, result.stderr)
            for artifact in ARTIFACTS:
                generated = consumer / artifact
                self.assertTrue(generated.is_file(), artifact)
                self.assertIn(PIN, generated.read_text(encoding="utf-8"), artifact)
            self.assertFalse((canonical / ".github/workflows/changelog.yml").exists())
            self.assertFalse((canonical / "scripts/changelog-contract.test.sh").exists())
            self.assertFalse((canonical / ".github/workflows/changelog-contract.yml").exists())
            self.assertEqual(renderer_before, (canonical / "scripts/render-next.sh").read_bytes())
            self.assertEqual(canonical_before, run("git", "status", "--porcelain=v1", cwd=canonical).stdout)

    def test_malformed_repository_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "OWNER/NAME"):
            module.render("Verjson/example/escape", ROOT)


if __name__ == "__main__":
    unittest.main()
