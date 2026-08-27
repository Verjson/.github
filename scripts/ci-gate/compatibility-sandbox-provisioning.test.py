#!/usr/bin/env python3
import copy
import pathlib

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
PROVISION = "Provision trusted compatibility sandbox"
NODE_EXECUTION = "Run runtime-resolved compatibility lanes without credentials"
HOSTED_EXECUTION = "Run namespace-bound compatibility contracts"
HOSTED_GATE = (
    "needs.eligibility.outputs.should-run != 'false' && "
    "(inputs.secretless-pr || inputs.secretless-trusted-ref) && "
    "inputs.secretless-compatibility-ranges != '' && "
    "runner.environment == 'github-hosted'"
)
SECRETLESS_ENV = {
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "",
    "ACTIONS_ID_TOKEN_REQUEST_URL": "",
    "AWS_ACCESS_KEY_ID": "",
    "AWS_SECRET_ACCESS_KEY": "",
    "AWS_SESSION_TOKEN": "",
    "AZURE_CREDENTIALS": "",
    "GH_TOKEN": "",
    "GITHUB_TOKEN": "",
    "GOOGLE_APPLICATION_CREDENTIALS": "",
    "NODE_AUTH_TOKEN": "",
    "NPM_TOKEN": "",
}
ABSOLUTE_PROVISIONER_PATHS = {
    "sudo": ("/usr/bin/sudo --non-interactive", "sudo --non-interactive", 2),
    "environment scrubber": ("/usr/bin/env -i", "env -i", 2),
    "apt": ("/usr/bin/apt-get", "apt-get", 2),
    "package status": ("/usr/bin/dpkg-query -W", "dpkg-query -W", 1),
    "package ownership": ("/usr/bin/dpkg-query -S", "dpkg-query -S", 1),
    "package version": (
        "/usr/bin/dpkg --compare-versions",
        "dpkg --compare-versions",
        1,
    ),
    "Python verifier": ("/usr/bin/python3 - <<'PY'", "python3 - <<'PY'", 1),
    "bubblewrap binary": ('path = "/usr/bin/bwrap"', 'path = "bwrap"', 1),
}


class ContractError(RuntimeError):
    pass


def load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def named_step(steps, name, owner):
    matches = [step for step in steps if step.get("name") == name]
    if not matches:
        raise ContractError(f"{owner} provisioner missing")
    if len(matches) != 1:
        raise ContractError(f"{owner} provisioner is ambiguous")
    return matches[0]


def require(source, snippet, reason):
    if snippet not in source:
        raise ContractError(reason)


def validate_source(source):
    if "apt-get upgrade" in source or "apt-get dist-upgrade" in source:
        raise ContractError("broad apt mutation is forbidden")
    for identity, (needle, _relative, expected_count) in (
        ABSOLUTE_PROVISIONER_PATHS.items()
    ):
        if source.count(needle) != expected_count:
            raise ContractError(f"absolute provisioner path drifted: {identity}")
    if source.count("/usr/bin/sudo --non-interactive /usr/bin/env -i") != 2:
        raise ContractError("signed apt acquisition boundary drifted")
    if source.count("/usr/bin/apt-get") != 2:
        raise ContractError("signed apt command count drifted")
    require(
        source,
        "update >/dev/null 2>&1",
        "signed apt index update command drifted",
    )
    if source.count("APT::Get::AllowUnauthenticated=false") != 2:
        raise ContractError("unauthenticated apt rejection drifted")
    if source.count("Acquire::AllowInsecureRepositories=false") != 2:
        raise ContractError("insecure apt repository rejection drifted")
    require(
        source,
        "install --yes --no-install-recommends bubblewrap >/dev/null 2>&1",
        "signed bubblewrap package acquisition missing",
    )
    require(
        source,
        "/usr/bin/dpkg --compare-versions \"$package_version\" ge '0.9.0-1build1'",
        "package version floor drifted",
    )
    require(
        source,
        "dpkg-query -S /usr/bin/bwrap",
        "package ownership verification missing",
    )
    require(source, "metadata.st_uid != 0", "binary root ownership verification missing")
    require(source, "metadata.st_gid != 0", "binary root group verification missing")
    require(
        source,
        "metadata.st_mode & 0o022",
        "binary writable-mode rejection missing",
    )
    require(
        source,
        "not metadata.st_mode & 0o111",
        "binary executable-bit verification missing",
    )
    require(source, "/usr/bin/python3 - <<'PY'", "absolute Python verifier drifted")
    require(source, '[path, "--version"]', "binary executable check missing")
    require(source, "< (0, 9, 0)", "binary version floor drifted")
    require(
        source,
        "::error::trusted bubblewrap package acquisition failed",
        "fixed acquisition diagnostic missing",
    )
    require(
        source,
        "::error::trusted bubblewrap binary identity or mode is unsafe",
        "fixed binary diagnostic missing",
    )
    if "self-hosted" in source:
        raise ContractError("self-hosted install fallback is forbidden")


def validate(node, actions):
    node_steps = node["jobs"]["build-test"]["steps"]
    node_provision = named_step(node_steps, PROVISION, "node-ci")
    if node_provision.get("if") != HOSTED_GATE:
        raise ContractError("node-ci provisioner is not gated to hosted compatibility execution")
    if node_provision.get("env") != SECRETLESS_ENV:
        raise ContractError("node-ci provisioner credential boundary drifted")
    node_source = node_provision.get("run", "")
    validate_source(node_source)
    provision_index = node_steps.index(node_provision)
    execution_indexes = [
        index for index, step in enumerate(node_steps)
        if step.get("name") == NODE_EXECUTION
    ]
    if len(execution_indexes) != 1 or provision_index >= execution_indexes[0]:
        raise ContractError("node-ci provisioning must precede compatibility execution")

    hosted_job = actions["jobs"].get("hosted-compatibility-tests")
    if not isinstance(hosted_job, dict) or hosted_job.get("runs-on") != "ubuntu-24.04":
        raise ContractError("actions-ci compatibility job is not explicitly hosted")
    hosted_steps = hosted_job["steps"]
    hosted_provision = named_step(hosted_steps, PROVISION, "actions-ci")
    if "if" in hosted_provision:
        raise ContractError("actions-ci hosted provisioner unexpectedly has a conditional")
    if hosted_provision.get("env") != SECRETLESS_ENV:
        raise ContractError("actions-ci provisioner credential boundary drifted")
    if hosted_provision.get("run") != node_source:
        raise ContractError("hosted mirror provisioning drifted")
    hosted_index = hosted_steps.index(hosted_provision)
    hosted_execution_indexes = [
        index for index, step in enumerate(hosted_steps)
        if step.get("name") == HOSTED_EXECUTION
    ]
    if len(hosted_execution_indexes) != 1 or hosted_index >= hosted_execution_indexes[0]:
        raise ContractError("actions-ci provisioning must precede compatibility contracts")


def expect_mutation(node, actions, reason, mutate):
    node_mutant = copy.deepcopy(node)
    actions_mutant = copy.deepcopy(actions)
    mutate(node_mutant, actions_mutant)
    try:
        validate(node_mutant, actions_mutant)
    except ContractError as error:
        if str(error) != reason:
            raise AssertionError(
                f"mutation failed for wrong reason: expected {reason!r}, got {str(error)!r}"
            ) from error
        print(f"ok - {reason}")
    else:
        raise AssertionError(f"mutation passed: {reason}")


def replace_node_source(node, old, new):
    step = next(
        step for step in node["jobs"]["build-test"]["steps"]
        if step.get("name") == PROVISION
    )
    if old not in step["run"]:
        raise AssertionError(f"mutation source absent: {old}")
    step["run"] = step["run"].replace(old, new, 1)


def replace_mirrored_source(node, actions, old, new):
    replace_node_source(node, old, new)
    step = next(
        step for step in actions["jobs"]["hosted-compatibility-tests"]["steps"]
        if step.get("name") == PROVISION
    )
    if old not in step["run"]:
        raise AssertionError(f"mirror mutation source absent: {old}")
    step["run"] = step["run"].replace(old, new, 1)


node_document = load(ROOT / ".github/workflows/node-ci.yml")
actions_document = load(ROOT / ".github/workflows/actions-ci.yml")
validate(node_document, actions_document)

for identity, (absolute, relative, _count) in ABSOLUTE_PROVISIONER_PATHS.items():
    expect_mutation(
        node_document,
        actions_document,
        f"absolute provisioner path drifted: {identity}",
        lambda node, actions, old=absolute, new=relative: replace_mirrored_source(
            node, actions, old, new
        ),
    )

expect_mutation(
    node_document,
    actions_document,
    "node-ci provisioner missing",
    lambda node, _actions: node["jobs"]["build-test"].__setitem__(
        "steps",
        [
            step for step in node["jobs"]["build-test"]["steps"]
            if step.get("name") != PROVISION
        ],
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "node-ci provisioner is not gated to hosted compatibility execution",
    lambda node, _actions: next(
        step for step in node["jobs"]["build-test"]["steps"]
        if step.get("name") == PROVISION
    ).__setitem__("if", "runner.environment == 'self-hosted'"),
)
expect_mutation(
    node_document,
    actions_document,
    "signed bubblewrap package acquisition missing",
    lambda node, _actions: replace_node_source(
        node,
        "install --yes --no-install-recommends bubblewrap >/dev/null 2>&1",
        "install --yes unrelated-package >/dev/null 2>&1",
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "signed apt index update command drifted",
    lambda node, actions: replace_mirrored_source(
        node,
        actions,
        "update >/dev/null 2>&1",
        "full-upgrade >/dev/null 2>&1",
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "unauthenticated apt rejection drifted",
    lambda node, _actions: replace_node_source(
        node,
        "APT::Get::AllowUnauthenticated=false",
        "APT::Get::AllowUnauthenticated=true",
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "node-ci provisioner credential boundary drifted",
    lambda node, _actions: next(
        step for step in node["jobs"]["build-test"]["steps"]
        if step.get("name") == PROVISION
    )["env"].__setitem__("GH_TOKEN", "inherited"),
)
expect_mutation(
    node_document,
    actions_document,
    "package version floor drifted",
    lambda node, _actions: replace_node_source(
        node, "'0.9.0-1build1'", "'0.1.0'"
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "binary root ownership verification missing",
    lambda node, _actions: replace_node_source(
        node, "metadata.st_uid != 0", "False"
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "package ownership verification missing",
    lambda node, _actions: replace_node_source(
        node,
        "/usr/bin/dpkg-query -S /usr/bin/bwrap",
        "/usr/bin/dpkg-query -S /tmp/bwrap",
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "binary writable-mode rejection missing",
    lambda node, _actions: replace_node_source(
        node, "metadata.st_mode & 0o022", "False"
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "binary executable-bit verification missing",
    lambda node, _actions: replace_node_source(
        node, "not metadata.st_mode & 0o111", "False"
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "binary executable check missing",
    lambda node, _actions: replace_node_source(
        node, '[path, "--version"]', "[path]"
    ),
)
expect_mutation(
    node_document,
    actions_document,
    "binary version floor drifted",
    lambda node, _actions: replace_node_source(node, "< (0, 9, 0)", "< (0, 1, 0)"),
)
expect_mutation(
    node_document,
    actions_document,
    "broad apt mutation is forbidden",
    lambda node, _actions: replace_node_source(
        node, "set -euo pipefail", "set -euo pipefail\n/usr/bin/apt-get upgrade"
    ),
)


def move_node_provisioner(node, _actions):
    steps = node["jobs"]["build-test"]["steps"]
    provision = next(step for step in steps if step.get("name") == PROVISION)
    steps.remove(provision)
    execution = next(
        index for index, step in enumerate(steps)
        if step.get("name") == NODE_EXECUTION
    )
    steps.insert(execution + 1, provision)


expect_mutation(
    node_document,
    actions_document,
    "node-ci provisioning must precede compatibility execution",
    move_node_provisioner,
)
expect_mutation(
    node_document,
    actions_document,
    "hosted mirror provisioning drifted",
    lambda _node, actions: next(
        step for step in actions["jobs"]["hosted-compatibility-tests"]["steps"]
        if step.get("name") == PROVISION
    ).__setitem__("run", "true\n"),
)
expect_mutation(
    node_document,
    actions_document,
    "actions-ci provisioner missing",
    lambda _node, actions: actions["jobs"]["hosted-compatibility-tests"].__setitem__(
        "steps",
        [
            step for step in actions["jobs"]["hosted-compatibility-tests"]["steps"]
            if step.get("name") != PROVISION
        ],
    ),
)


def move_hosted_provisioner(_node, actions):
    steps = actions["jobs"]["hosted-compatibility-tests"]["steps"]
    provision = next(step for step in steps if step.get("name") == PROVISION)
    steps.remove(provision)
    execution = next(
        index for index, step in enumerate(steps)
        if step.get("name") == HOSTED_EXECUTION
    )
    steps.insert(execution + 1, provision)


expect_mutation(
    node_document,
    actions_document,
    "actions-ci provisioning must precede compatibility contracts",
    move_hosted_provisioner,
)
print("ok - hosted signed bubblewrap provisioning is secretless, ordered, and mirrored")
