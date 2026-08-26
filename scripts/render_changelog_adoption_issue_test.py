import importlib.util
import json
import os
import re
import shutil
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
    env = os.environ.copy()
    env["GIT_AUTHOR_DATE"] = "2000-01-01T00:00:00+00:00"
    env["GIT_COMMITTER_DATE"] = "2000-01-01T00:00:00+00:00"
    result = run(
        "git",
        "-c",
        "user.name=contract-test",
        "-c",
        "user.email=contract-test@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--allow-empty",
        "-m",
        message,
        cwd=root,
        env=env,
    )
    if result.returncode != 0:
        raise AssertionError(result.stderr)
    return run("git", "rev-parse", "HEAD", cwd=root).stdout.strip()


def create_canonical_fixture(root: Path) -> str:
    initialized = run("git", "init", "-q", cwd=root)
    if initialized.returncode != 0:
        raise AssertionError(initialized.stderr)
    floor = commit(root, "capability floor")
    contract_files = (module.CHANGELOG_GENERATOR, "scripts/changelog.py")
    for contract_file in contract_files:
        destination = root / contract_file
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / contract_file, destination)
    staged = run("git", "add", *contract_files, cwd=root)
    if staged.returncode != 0:
        raise AssertionError(staged.stderr)
    recommendation = commit(root, "recommended changelog contract")
    (root / "config").mkdir()
    (root / "config/capability-floors.json").write_text(
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
    staged = run("git", "add", "config/capability-floors.json", cwd=root)
    if staged.returncode != 0:
        raise AssertionError(staged.stderr)
    commit(root, "register recommended changelog contract")
    return recommendation


class AdoptionIssueTest(unittest.TestCase):
    def test_render_uses_machine_readable_recommendation_and_current_context(self):
        registry = json.loads((ROOT / "config/capability-floors.json").read_text(encoding="utf-8"))
        self.assertEqual(PIN, registry["recommended_pins"][module.CHANGELOG_GENERATOR])
        with tempfile.TemporaryDirectory() as tmp:
            canonical = Path(tmp)
            recommendation = create_canonical_fixture(canonical)

            text = module.render("Verjson/example", canonical)

            self.assertIn(recommendation, text)
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
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            canonical = tmp_path / "canonical"
            consumer = tmp_path / "consumer"
            canonical.mkdir()
            recommendation = create_canonical_fixture(canonical)
            text = module.render("Verjson/example", canonical)
            match = re.search(r"```bash\n(.*?)\n```", text, re.DOTALL)
            self.assertIsNotNone(match)
            consumer.mkdir()
            initialized = run("git", "init", "-q", cwd=consumer)
            self.assertEqual(0, initialized.returncode, initialized.stderr)
            canonical_before = run("git", "status", "--porcelain=v1", cwd=canonical).stdout
            env = os.environ.copy()
            env["CONTRACT_SOURCE_URL"] = str(canonical)

            result = run("bash", "-c", match.group(1), cwd=consumer, env=env)

            self.assertEqual(0, result.returncode, result.stderr)
            for artifact in ARTIFACTS:
                generated = consumer / artifact
                self.assertTrue(generated.is_file(), artifact)
                self.assertIn(recommendation, generated.read_text(encoding="utf-8"), artifact)
            for artifact in ARTIFACTS:
                self.assertFalse((canonical / artifact).exists(), artifact)
            self.assertEqual(canonical_before, run("git", "status", "--porcelain=v1", cwd=canonical).stdout)

    def test_malformed_repository_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "OWNER/NAME"):
            module.render("Verjson/example/escape", ROOT)


if __name__ == "__main__":
    unittest.main()
