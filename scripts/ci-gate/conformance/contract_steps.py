#!/usr/bin/env python3
"""Run a contract step's own script, rather than a paraphrase of it.

`model.py` reasons about *which* steps a lane executes. It deliberately cannot
reason about what a step decides once it runs: the secretless boundary and the
approved-package allowlist are enforced inside a `run:` script — one of them an
embedded Python program — and a model that inferred their verdicts from shell
layout would be asserting against a paraphrase that drifts silently from the
contract.

So this module extracts the step's script from the contract and executes it,
unmodified, in a sandbox the test builds. What is asserted is then the
contract's own refusal, byte for byte with what an adopter's runner executes.

The extraction is fail-closed twice over: a step name the contract no longer
declares raises, and the environment names a caller binds must be exactly the
ones the step declares. A step whose script silently stopped being reached, or
whose inputs were renamed, would otherwise keep passing a test that has
stopped exercising anything — the harness's own Verjson/verjson-ci#184.
"""

from __future__ import annotations

import contextlib
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

import yaml


class MissingContractStep(Exception):
    """The contract no longer declares the step a test claims to exercise."""


class StepEnvironmentMismatch(Exception):
    """A caller binds environment names the step does not declare, or omits some."""


# `${{ ... }}` in a step's `env:` value is resolved by the runner, so a test
# supplying that value is not overriding the contract — it is standing in for
# the runner. A literal value is the contract's own and is used as declared.
_EXPRESSION = re.compile(r'\$\{\{.*\}\}', re.DOTALL)


@dataclass(frozen=True)
class StepResult:
    """What a contract step's script did.

    `output` carries both streams, because asserting a *refusal's reason* is
    what separates "the contract refused this for the reason under test" from
    "the contract refused this at all" — and the second is satisfied by a
    fixture that has quietly drifted into being malformed.
    """

    status: int
    output: str

    @property
    def admitted(self) -> bool:
        return self.status == 0


@dataclass(frozen=True)
class ContractStep:
    job: str
    name: str
    script: str
    runner_supplied_env: frozenset[str]
    literal_env: dict[str, str]


def locate_step(contract: Path, job: str, name: str) -> ContractStep:
    """Return the named step of `job`, with its script and env surface."""
    workflow = yaml.safe_load(contract.read_text(encoding='utf-8'))
    jobs = workflow.get('jobs') or {}
    if job not in jobs:
        raise MissingContractStep(f'{contract.name} declares no job {job!r}')
    for step in jobs[job].get('steps') or []:
        if step.get('name') != name:
            continue
        script = step.get('run')
        if not script:
            raise MissingContractStep(
                f'{contract.name}: {job}/{name!r} is no longer a `run:` step, '
                'so executing its script no longer exercises the contract')
        declared = step.get('env') or {}
        runner_supplied = {
            key for key, value in declared.items()
            if isinstance(value, str) and _EXPRESSION.search(value)}
        literal = {
            key: str(value) for key, value in declared.items()
            if key not in runner_supplied}
        return ContractStep(job, name, script, frozenset(runner_supplied), literal)
    raise MissingContractStep(
        f'{contract.name}: {job} declares no step named {name!r}; a test '
        'naming a step the contract dropped exercises nothing')


def execute_step(step: ContractStep, bindings: dict[str, str], *,
                 workspace: Path | None = None) -> StepResult:
    """Run `step`'s script and return its status and combined output.

    `bindings` stands in for the runner: it must name exactly the step's
    expression-valued `env:` entries. Supplying a name the step does not
    declare, or omitting one it does, raises — an extra name would silently
    assert against an input the contract stopped reading, and a missing one
    would leave the script reading an unset variable under `set -u`, which is a
    refusal for a reason the contract never expressed.

    Literal `env:` values come from the contract itself and are not overridable
    here; they are part of what is being exercised.
    """
    supplied = set(bindings)
    if supplied != set(step.runner_supplied_env):
        raise StepEnvironmentMismatch(
            f'{step.job}/{step.name!r} declares runner-supplied env '
            f'{sorted(step.runner_supplied_env)}; the caller bound '
            f'{sorted(supplied)}')

    with _sandbox(workspace) as cwd:
        completed = subprocess.run(
            ['bash', '-c', step.script],
            cwd=cwd,
            # A closed environment: the script sees the step's declared inputs
            # and nothing the developer's shell happened to export. PATH and
            # HOME are the runner's own baseline, not contract inputs.
            env={'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
                 'HOME': str(cwd),
                 **step.literal_env,
                 **{key: str(value) for key, value in bindings.items()}},
            capture_output=True,
            text=True,
            timeout=120,
        )
    return StepResult(completed.returncode, completed.stdout + completed.stderr)


@contextlib.contextmanager
def _sandbox(workspace: Path | None):
    """Run in the caller's workspace, or in a throwaway one it does not need.

    Never the repository checkout: a contract step writes files and reads
    `package-lock.json` from its working directory, and one that ran against
    this repository would both mutate it and pass or fail on its contents.
    """
    if workspace is not None:
        yield workspace
        return
    with tempfile.TemporaryDirectory() as scratch:
        yield Path(scratch)
