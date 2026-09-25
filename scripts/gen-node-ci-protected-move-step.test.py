#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts/gen-node-ci-protected.py"


def load_generator():
    spec = importlib.util.spec_from_file_location("gen_node_ci_protected", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MoveStepBeforeGuardBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.module = load_generator()

    def test_a_non_step_bullet_at_six_spaces_inside_the_moving_step_does_not_truncate_it(self):
        # The moving step's own run: block happens to emit a line that is
        # indented exactly six spaces and starts with "- ", but is not a
        # step marker (no "name:"/"uses:" key). The real next step follows
        # further down; the boundary scan must not stop early on it.
        document = (
            "jobs:\n"
            "  example:\n"
            "    steps:\n"
            "      - name: Guard step\n"
            "        run: guard\n"
            "      - name: Before step\n"
            "        run: before\n"
            "      - name: Move me\n"
            "        run: |\n"
            "          cat <<'YAML'\n"
            "      - some: embedded-fixture-line\n"
            "          YAML\n"
            "      - name: Trailing step\n"
            "        run: trailing\n"
        )
        result = self.module.move_step_before_guard(
            document, "Move me", "Before step", "Guard step"
        )
        self.assertIn("cat <<'YAML'\n", result)
        self.assertIn("some: embedded-fixture-line\n", result)
        self.assertIn("          YAML\n", result)
        lines = result.splitlines(keepends=True)
        moved_index = lines.index("      - name: Move me\n")
        guard_index = lines.index("      - name: Guard step\n")
        trailing_index = lines.index("      - name: Trailing step\n")
        self.assertLess(moved_index, guard_index)
        self.assertGreater(trailing_index, guard_index)

    def test_no_step_marker_after_the_moving_step_fails_closed(self):
        document = (
            "jobs:\n"
            "  example:\n"
            "    steps:\n"
            "      - name: Guard step\n"
            "        run: guard\n"
            "      - name: Before step\n"
            "        run: before\n"
            "      - name: Move me\n"
            "        run: |\n"
            "          echo done\n"
        )
        with self.assertRaises(SystemExit):
            self.module.move_step_before_guard(
                document, "Move me", "Before step", "Guard step"
            )


if __name__ == "__main__":
    unittest.main()
