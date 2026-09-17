#!/usr/bin/env python3
"""Regression suite for scripts/fleet-contract-inventory.py.

The assertion that matters is the fail-open one: a sweep that cannot resolve a
ref must report UNKNOWN, never CURRENT. The invalid predecessor test reported
"current" whenever both of its API calls failed, which is how the `#184` drift
survived a sweep written to find it.
"""
import importlib.util
import pathlib
import unittest

_root = pathlib.Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location(
    "fleet_contract_inventory", _root / "scripts" / "fleet-contract-inventory.py")
fci = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fci)

A = "a" * 40
B = "b" * 40
PATH = ".github/workflows/node-ci.yml"


class Classify(unittest.TestCase):
    def test_equal_resolved_object_ids_are_current(self):
        self.assertEqual(fci.classify(PATH, {PATH: A}, {PATH: A}), "CURRENT")

    def test_differing_resolved_object_ids_are_drifted(self):
        self.assertEqual(fci.classify(PATH, {PATH: A}, {PATH: B}), "DRIFTED")

    def test_an_unresolvable_pinned_tree_is_unknown_not_current(self):
        self.assertEqual(fci.classify(PATH, None, {PATH: A}), "UNKNOWN")

    def test_an_unresolvable_default_tree_is_unknown_not_current(self):
        self.assertEqual(fci.classify(PATH, {PATH: A}, None), "UNKNOWN")

    def test_two_unresolvable_trees_do_not_compare_equal(self):
        # The exact predecessor defect: `[ "" = "" ]` is true.
        self.assertEqual(fci.classify(PATH, None, None), "UNKNOWN")

    def test_a_path_absent_from_either_tree_is_unknown(self):
        self.assertEqual(fci.classify(PATH, {}, {PATH: A}), "UNKNOWN")
        self.assertEqual(fci.classify(PATH, {PATH: A}, {}), "UNKNOWN")

    def test_two_empty_trees_do_not_compare_equal(self):
        self.assertEqual(fci.classify(PATH, {}, {}), "UNKNOWN")

    def test_a_malformed_object_id_is_unknown_not_current(self):
        self.assertEqual(fci.classify(PATH, {PATH: "not-a-sha"},
                                      {PATH: "not-a-sha"}), "UNKNOWN")


class UsesExtraction(unittest.TestCase):
    def test_extracts_path_and_pin_from_a_hub_reference(self):
        text = f"    uses: Verjson/.github/.github/workflows/node-ci.yml@{A}\n"
        found = [(m.group("path"), m.group("sha"))
                 for m in fci.USES_RE.finditer(text)]
        self.assertEqual(found, [(".github/workflows/node-ci.yml", A)])

    def test_ignores_a_reference_to_another_owner(self):
        text = f"    uses: OtherOrg/.github/.github/workflows/node-ci.yml@{A}\n"
        self.assertEqual(list(fci.USES_RE.finditer(text)), [])

    def test_ignores_a_moving_tag_because_it_is_not_a_pin(self):
        text = "    uses: Verjson/.github/.github/workflows/node-ci.yml@v1\n"
        self.assertEqual(list(fci.USES_RE.finditer(text)), [])

    def test_finds_every_distinct_pin_in_one_file(self):
        text = (f"  uses: Verjson/.github/.github/workflows/node-ci.yml@{A}\n"
                f"  uses: Verjson/.github/.github/workflows/changelog.yml@{B}\n")
        self.assertEqual({m.group("sha") for m in fci.USES_RE.finditer(text)},
                         {A, B})


if __name__ == "__main__":
    unittest.main(verbosity=2)
