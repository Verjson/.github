#!/usr/bin/env python3
"""Conformance matrix: the contract, against synthetic adopters, before release.

`Verjson/verjson-ci#184` was a contract defect, not adopter drift. `node-ci.yml`
was published in a state where a deferred head reported `ci / build-test`
SUCCESS having executed nothing, and no adopter was positioned to catch it — a
reusable workflow is only exercised by real callers, after publication.

The property every case here asserts is **positive evidence of execution**, not
absence of red. A suite that only asserts "the run was green" reproduces the
exact defect it exists to prevent: #184 was green.

Step 3 of the contract-distribution sequence (Verjson/.github#1369, ADR 0185).
"""

import sys
import tempfile
import unittest
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))

from adopter import ADOPTERS, AdopterContractMismatch, bind_inputs, callers_for  # noqa: E402
from expressions import Evaluator, UnknownContext, UnsupportedExpression  # noqa: E402
from model import Scenario, model_workflow  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
CONTRACT = ROOT / '.github/workflows/node-ci.yml'
PROTECTED_CONTRACT = ROOT / '.github/workflows/node-ci-protected.yml'
PRE_ADR_0178 = (Path(__file__).resolve().parent
                / 'regressions/node-ci-pre-adr-0178.yml')

# A merge predicate may treat these as satisfying a required context; anything
# else is a positive signal that something did not go to plan. Keeping the set
# here, next to the property it defines, is deliberate: widening it is what
# reopens Verjson/verjson-ci#184, and it should take an edit someone reviews.
CONCLUSIONS_A_MERGE_GATE_ACCEPTS = frozenset({'success', 'skipped', 'neutral'})

# The steps whose presence in a run is the evidence that the lane did real
# work — the credentialed lane's package scripts, and the secretless lane's
# script plan. A lane reporting success without one of these has reported #184.
#
# These are exact step names rather than substrings, and
# `test_every_registered_work_step_still_exists` asserts each one is still in
# the contract. An evidence list that silently stops matching is worse than no
# evidence list: every lane then looks like it did nothing, or — depending on
# which way the assertion runs — like it did something.
WORK_STEPS = frozenset({
    'Run exact credentialless consumer script plan',
    'npm ci',
    'npm run build',
    'npm test',
})

# What each (adopter, scenario) pair must execute, exactly. Asserting only that
# *some* evidence exists accepts a contract that guards off `npm test` while
# leaving `npm ci` running — a partial #184, and the shape a defect is most
# likely to take once the obvious one is tested for.
#
# The key is the pair, not the adopter: `typescript-service.yml` happens to opt
# into the secretless lane on both events, but the realistic adopter shape is
# secretless on pull_request and credentialed on push, and an adopter-keyed
# table cannot express it.
CREDENTIALED = frozenset({'npm ci', 'npm run build', 'npm test'})
SECRETLESS = frozenset({'Run exact credentialless consumer script plan'})
EXPECTED_EVIDENCE = {
    ('minimal-defaults.yml', 'secretless-pr'): CREDENTIALED,
    ('minimal-defaults.yml', 'trusted-ref-push'): CREDENTIALED,
    ('typescript-service.yml', 'secretless-pr'): SECRETLESS,
    ('typescript-service.yml', 'trusted-ref-push'): SECRETLESS,
}

# Context values a caller cannot supply: they come from the event and from jobs
# the contract runs itself. A scenario is exactly a choice of these.
def scenario_bindings(*, should_run, event_name='pull_request',
                      auxiliary_path='', cache_hits=False, hosted=True):
    return {
        'github.event_name': event_name,
        'github.event.pull_request.head.repo.full_name': 'fork/verjson-ci',
        'github.event.pull_request.head.sha': '0' * 40,
        'needs.eligibility.outputs.should-run': should_run,
        'needs.acquire-secretless-dependencies.outputs.auxiliary-content-path': auxiliary_path,
        'steps.restore-secretless-public-cache.outputs.cache-hit': 'true' if cache_hits else '',
        'steps.restore-playwright-browser-cache.outputs.cache-hit': 'true' if cache_hits else '',
        'steps.prepare-playwright-browser-cache.outputs.owned': 'true',
        'steps.bound-playwright-browser-cache.outputs.should-save': 'true',
        'runner.environment': 'github-hosted' if hosted else 'self-hosted',
    }


SCENARIOS = (
    Scenario(
        name='deferred',
        description='eligibility defers the run (a held Renovate PR)',
        bindings=scenario_bindings(should_run='false'),
        functions={'hashFiles': lambda *_: ''},
    ),
    Scenario(
        name='secretless-pr',
        description='pull-request lane; secretless for an adopter that opts in',
        bindings=scenario_bindings(should_run='true', event_name='pull_request'),
        functions={'hashFiles': lambda *_: 'deadbeef'},
    ),
    Scenario(
        name='trusted-ref-push',
        description='push to a trusted ref',
        bindings=scenario_bindings(should_run='true', event_name='push'),
        functions={'hashFiles': lambda *_: 'deadbeef'},
    ),
)


def jobs_a_merge_gate_would_reject(contract, caller, binds_as=None):
    """The deferred run's jobs that an all-SUCCESS assertion would reject.

    This is the whole of ADR 0178 stated as a predicate: not "is the run
    green", but "does the rollup carry an entry that an all-SUCCESS assertion
    would reject". Returning the job names rather than a boolean is deliberate
    — a spurious failure anywhere else in the contract would otherwise satisfy
    the property for the wrong reason, and look identical to conformance.
    """
    outcomes = outcomes_for(contract, caller, SCENARIOS[0], binds_as)
    return {name for name, outcome in outcomes.items()
            if outcome.conclusion not in CONCLUSIONS_A_MERGE_GATE_ACCEPTS}


def outcomes_for(contract, caller, scenario, binds_as=None):
    bindings = dict(scenario.bindings)
    # A caller's `with:` values are expressions evaluated in the *caller's*
    # context, so `secretless-pr: ${{ github.event_name == \'pull_request\' }}`
    # is what makes one fixture serve both the PR and the push lane. Binding the
    # literal string instead would make every such input permanently truthy and
    # quietly collapse the scenarios into one.
    caller_evaluator = Evaluator(bindings, functions={'always': lambda: True})
    for name, value in bind_inputs(contract, caller, binds_as).items():
        if isinstance(value, str) and value.strip().startswith('${{'):
            bindings[name] = caller_evaluator.evaluate(value)
        else:
            bindings[name] = value
    resolved = Scenario(scenario.name, scenario.description, bindings, scenario.functions)
    return model_workflow(contract, resolved)


class DeferredLaneIsDistinguishableFromSuccess(unittest.TestCase):
    """The #184 regression test. It must fail against a pre-ADR-0178 contract."""

    def test_a_deferred_run_publishes_a_check_that_is_not_success(self):
        for contract in (CONTRACT, PROTECTED_CONTRACT):
            for caller in callers_for(contract):
                with self.subTest(contract=contract.name, adopter=caller.name):
                    self.assertEqual(
                        {'deferred-ci'},
                        jobs_a_merge_gate_would_reject(contract, caller),
                        'a deferred head must publish exactly one non-SUCCESS '
                        'check, ADR 0178\'s `deferred-ci`. Nothing there means a '
                        'merge gate cannot tell a deferred head from a verified '
                        'one (Verjson/verjson-ci#184); anything else means the '
                        'signal a gate acts on is a spurious failure')

    def test_the_property_fails_against_the_contract_that_shipped_the_defect(self):
        """A regression test that passes against the defect proves nothing."""
        for caller in callers_for(CONTRACT):
            with self.subTest(adopter=caller.name):
                self.assertEqual(
                    set(),
                    jobs_a_merge_gate_would_reject(PRE_ADR_0178, caller,
                                                   binds_as=CONTRACT.name),
                    'the pre-ADR-0178 contract now looks conformant, so this '
                    'matrix would not have caught Verjson/verjson-ci#184 — '
                    'either the fixture drifted or the property weakened')

    def test_the_counter_example_differs_from_the_contract_only_by_the_deferred_job(self):
        """Otherwise the counter-example drifts and the test above passes for free.

        The fixture is a YAML round-trip of the contract, so it cannot be
        compared byte for byte; comparing the parsed documents is what makes
        `deferred-ci` provably the only difference, and keeps an unrelated
        upstream edit from quietly turning the regression test into a tautology.
        """
        contract = yaml.safe_load(CONTRACT.read_text(encoding='utf-8'))
        counter_example = yaml.safe_load(PRE_ADR_0178.read_text(encoding='utf-8'))
        removed = contract['jobs'].pop('deferred-ci', None)
        self.assertIsNotNone(removed, 'the contract no longer declares deferred-ci')
        self.assertEqual(
            contract, counter_example,
            'the counter-example differs from the contract by more than the '
            'deferred-ci job, so what it proves about Verjson/verjson-ci#184 '
            'is no longer what it claims to prove')

    def test_a_deferred_run_executes_no_work_while_the_required_context_reports(self):
        for caller in callers_for(CONTRACT):
            with self.subTest(adopter=caller.name):
                outcomes = outcomes_for(CONTRACT, caller, SCENARIOS[0])
                build_test = outcomes['build-test']
                self.assertTrue(
                    build_test.ran,
                    'the required context must still report, or a held Renovate PR '
                    'wedges on a permanently unsatisfied check (Verjson/.github#191)')
                executed = sorted(WORK_STEPS & set(build_test.executed_steps))
                self.assertEqual(
                    [], executed,
                    'a deferred run executed work steps; the scenario no longer '
                    f'models deferral: {executed}')


class EveryExecutingLaneShowsPositiveEvidence(unittest.TestCase):
    def test_a_lane_that_runs_executes_steps_that_do_the_work(self):
        for scenario in SCENARIOS[1:]:
            for caller in callers_for(CONTRACT):
                with self.subTest(scenario=scenario.name, adopter=caller.name):
                    outcomes = outcomes_for(CONTRACT, caller, scenario)
                    key = (caller.name, scenario.name)
                    self.assertIn(
                        key, EXPECTED_EVIDENCE,
                        'a synthetic adopter with no registered evidence: add '
                        'what its lane must execute rather than leaving the '
                        'matrix silent about it')
                    evidence = WORK_STEPS & set(outcomes['build-test'].executed_steps)
                    self.assertEqual(
                        EXPECTED_EVIDENCE[key], evidence,
                        f'{scenario.name} did not execute the work its lane is '
                        'defined by; a lane reporting success on less than this '
                        'is Verjson/verjson-ci#184, whole or in part')

    def test_a_lane_that_runs_concludes_successfully(self):
        """The lane is neither skipped nor unconditionally failing.

        That is the honest statement of what this can detect: the model derives
        `failure` only from an unconditional top-level `exit`, so the
        contract's guarded error paths are all modelled as succeeding. Without
        it, though, a lane modelled as failing would satisfy every other
        property here by accident — spurious red looks like conformance to an
        assertion that only ever demands a non-SUCCESS entry somewhere.
        """
        for scenario in SCENARIOS[1:]:
            for caller in callers_for(CONTRACT):
                with self.subTest(scenario=scenario.name, adopter=caller.name):
                    outcomes = outcomes_for(CONTRACT, caller, scenario)
                    self.assertEqual(
                        'success', outcomes['build-test'].conclusion,
                        'the healthy lane does not conclude successfully, so '
                        'every other assertion here is reading a model of a '
                        'contract nobody could merge against')


class TheEvidenceRegistryMatchesTheContract(unittest.TestCase):
    def test_every_registered_work_step_still_exists(self):
        steps = yaml.safe_load(CONTRACT.read_text(encoding='utf-8'))['jobs']['build-test']['steps']
        names = {step.get('name') or str(step.get('run', '')).strip() for step in steps}
        missing = sorted(WORK_STEPS - names)
        self.assertEqual(
            [], missing,
            'the evidence registry names steps the contract no longer has; a '
            'renamed work step makes every execution assertion vacuous')

    def test_every_expected_step_is_one_the_registry_can_match(self):
        """Assertions compare against `WORK_STEPS & executed`, so a typo in an
        expected name is permanently unsatisfiable rather than caught."""
        for key, expected in EXPECTED_EVIDENCE.items():
            with self.subTest(case=key):
                self.assertEqual(
                    set(), expected - WORK_STEPS,
                    'an expected step outside the work-step registry can never '
                    'appear in the evidence set, so this case can never pass')


class TheAdopterSurfaceIsTheContractSurface(unittest.TestCase):
    def test_every_synthetic_adopter_binds_against_the_contract(self):
        for contract in (CONTRACT, PROTECTED_CONTRACT):
            for caller in callers_for(contract):
                with self.subTest(contract=contract.name, adopter=caller.name):
                    bindings = bind_inputs(contract, caller)
                    self.assertTrue(bindings, f'{caller.name} bound no inputs at all')

    def test_an_adopter_passing_an_undeclared_input_is_rejected(self):
        # Outside `adopters/`: an interrupted run must not leave a fixture that
        # `callers_for` then globs into every subsequent test.
        with tempfile.TemporaryDirectory() as scratch:
            drifted = Path(scratch) / 'drifted-adopter.yml'
            drifted.write_text(
                (ADOPTERS / 'typescript-service.yml').read_text(encoding='utf-8')
                + '      node-verison: 24\n', encoding='utf-8')
            with self.assertRaises(AdopterContractMismatch):
                bind_inputs(CONTRACT, drifted)


class TheHarnessFailsClosed(unittest.TestCase):
    """The harness's own #184: a model that guesses cannot assert anything."""

    def test_an_unbound_context_raises_rather_than_defaulting(self):
        scenario = Scenario('unbound', 'missing a binding the contract reads', {})
        with self.assertRaises(UnknownContext):
            model_workflow(CONTRACT, scenario)

    def test_an_unsupported_construct_raises_rather_than_evaluating_false(self):
        with self.assertRaises(UnsupportedExpression):
            Evaluator({}).evaluate("fromJSON('[]')")

    def test_a_status_function_nothing_bound_raises_the_modules_own_error(self):
        """A bare NameError reads as a harness crash, not an unmodelled guard."""
        with self.assertRaises(UnsupportedExpression):
            Evaluator({}, functions={}).evaluate('success()')


if __name__ == '__main__':
    unittest.main()
