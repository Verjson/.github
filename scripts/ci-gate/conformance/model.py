#!/usr/bin/env python3
"""Statically model what a reusable workflow does for one synthetic adopter.

A reusable workflow is only ever exercised by real callers, after publication,
so a contract defect reaches every adopter before anyone sees it. That is how
`Verjson/verjson-ci#184` shipped: `build-test` reported SUCCESS on a deferred
head having executed no test, lint, type check, or contract guard.

This module evaluates the contract's job and step guards against a scenario's
input bindings and reports, per job, whether it ran and whether any step that
does real work ran. The properties asserted on top of that model live in
conformance.test.py; nothing here decides what is acceptable.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml

from expressions import Evaluator


@dataclass(frozen=True)
class Scenario:
    """One synthetic adopter's call into the contract.

    `bindings` supplies every context value the contract's guards read. A guard
    reading something unbound raises rather than defaulting, so adding a guard
    upstream surfaces here as a failing scenario instead of a silent change in
    what the harness believes executed.
    """

    name: str
    description: str
    bindings: dict[str, object]
    functions: dict[str, object] = field(default_factory=dict)


@dataclass
class JobOutcome:
    name: str
    ran: bool
    executed_steps: list[str] = field(default_factory=list)
    skipped_steps: list[str] = field(default_factory=list)
    terminates_unsuccessfully: bool = False

    @property
    def conclusion(self) -> str:
        """The conclusion this job contributes to a caller's check rollup.

        The three values a merge predicate has to tell apart: `skipped` and
        `success` are both things a naive all-SUCCESS assertion accepts, and
        `failure` is the only one that makes a deferred head distinguishable
        from a verified one.
        """
        if not self.ran:
            return 'skipped'
        return 'failure' if self.terminates_unsuccessfully else 'success'


def _terminates_unsuccessfully(step: dict) -> bool:
    """Whether running this step concludes its job as a failure.

    Only an unconditional `exit <non-zero>` counts. Deliberate failure is how
    ADR 0178's deferral makes itself visible in a check rollup rather than in an
    annotation an opt-in script has to read, so the model has to represent it —
    a model in which every job that runs succeeds cannot express the difference
    the whole conformance matrix is about.
    """
    for line in str(step.get('run', '')).splitlines():
        line = line.strip()
        if line.startswith('exit ') and line[5:].strip().isdigit():
            return line[5:].strip() != '0'
    return False


def _step_label(step: dict) -> str:
    return step.get('name') or step.get('uses') or str(step.get('run', ''))[:60]


def model_workflow(path: Path, scenario: Scenario) -> dict[str, JobOutcome]:
    """Return one outcome per job in `path` under `scenario`.

    Job results feed later guards, so jobs are walked in declaration order and
    each job's result is bound before the next job's guard is evaluated. The
    contract declares its jobs in dependency order; a workflow that does not is
    a defect this harness should surface rather than tolerate.
    """
    workflow = yaml.safe_load(path.read_text(encoding='utf-8'))
    bindings = dict(scenario.bindings)
    outcomes: dict[str, JobOutcome] = {}

    for job_name, job in workflow['jobs'].items():
        # `needs:` is a scalar when there is one dependency and a list when
        # there are several. Iterating the scalar walks its characters.
        needs = job.get('needs') or []
        for dependency in [needs] if isinstance(needs, str) else needs:
            if dependency not in outcomes:
                raise ValueError(
                    f'{path.name}: job {job_name!r} needs {dependency!r}, '
                    'which is declared after it')

        evaluator = Evaluator(
            bindings, functions={'always': lambda: True, **scenario.functions})
        ran = evaluator.evaluate(job.get('if'))
        outcome = JobOutcome(name=job_name, ran=ran)

        if ran:
            for step in job.get('steps') or []:
                if evaluator.evaluate(step.get('if')):
                    outcome.executed_steps.append(_step_label(step))
                    if _terminates_unsuccessfully(step):
                        outcome.terminates_unsuccessfully = True
                else:
                    outcome.skipped_steps.append(_step_label(step))

        outcomes[job_name] = outcome
        bindings[f'needs.{job_name}.result'] = outcome.conclusion

    return outcomes
