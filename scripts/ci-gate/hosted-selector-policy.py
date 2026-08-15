#!/usr/bin/env python3
"""Refuse metered GitHub-hosted runner selectors and unbounded hosted jobs.

    hosted-selector-policy.py --visibility public|private [--sanctioned NAME]... <workflow-dir>

Exit 0 is "scanned and clean", 1 is "policy violation", 2 is "undetermined".
The three are distinct because a sweep that scans nothing must not look like a
sweep that found nothing — the convention scripts/runner-selector-health.sh uses,
and the reason it exits 2 rather than 0 when it cannot decide.

Verjson/.github#814, ADR 0103.

WHY THIS IS A REAL YAML PARSER (#818 review)
--------------------------------------------
The first implementation matched `runs-on:` with line-oriented shell patterns.
Two review passes found five parser-level false negatives in shapes GitHub
accepts and the patterns did not: a TAB/IFS field collapse, a matrix indirection,
a flow-style job body (`mac: {runs-on: macos-latest, ...}`), a flow-mapping
`jobs:`, and `runs-on : macos-15` with a space before the colon. Each returned
exit 0 on a genuinely metered job.

That rate is the argument. This script is the single control between the
organization and metered spend, and a false negative here is silent and costs
money, so the parser must be one that understands the language rather than one
that recognises the shapes someone thought of. Every remaining unknown evasion in
the hand-rolled parser was an unknown; there is no such class left here, because
anything PyYAML cannot resolve is refused rather than guessed at.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

import yaml

# ---------------------------------------------------------------------------
# Policy constants
# ---------------------------------------------------------------------------

# R1 (Tier A) — the metered SKU families, refused outright.
#
# No allowlist, no parameter, no environment override, and deliberately NOT keyed
# on repository visibility. Visibility is a mutable organization-settings fact,
# and encoding it in workflow YAML is exactly the "stale by construction" defect
# ADR 0033 diagnosed and ADR 0040 watched regrow four times (#175, #182, #192,
# #203). A public repository flipped private turns a free `macos-latest` job into
# a 10x metered one with no commit, no review, and no signal.
#
# Preceded by a non-word character so `VERJSON_LANE_TRUSTED_MACOS` — the lane
# variable NAME, governed by R5 — is not read as a macOS selector.
METERED_FAMILY = re.compile(r"(?:^|[^A-Za-z0-9_])(?:macos|windows)-[A-Za-z0-9]", re.I)
METERED_LATEST = re.compile(r"(?:^|[^A-Za-z0-9_])(?:macos|windows)-latest", re.I)
LINUX_HOSTED_LITERAL = re.compile(r"(?:^|[^A-Za-z0-9_])ubuntu-[A-Za-z0-9]", re.I)

# The OS-scoped lanes of ADR 0103. Repository variables on the one desktop
# repository, never organization variables, so a workflow anywhere else resolves
# them to empty.
OS_LANE = re.compile(r"vars\.VERJSON_LANE_TRUSTED_(?:MACOS|WINDOWS)")
OS_LANE_TEXT = re.compile(r"VERJSON_LANE_TRUSTED_(?:MACOS|WINDOWS)")

# Any Verjson placement variable EXCEPT the OS lanes, which are governed by the
# inverted rule. Broadened from LANE_(TRUSTED|UNTRUSTED|PRIVILEGED) after review:
# a chain on `vars.VERJSON_RUNNER_FASTLANE` or `VERJSON_RUNNER_OVERFLOW` with no
# tail hits the #401 forever-queue mode just as squarely, and was unguarded.
PLACEMENT_VARIABLE = re.compile(
    r"vars\.VERJSON_(?:LANE|RUNNER)_(?!TRUSTED_MACOS|TRUSTED_WINDOWS)[A-Z_]+"
)
TERMINAL_LANDING = re.compile(r"vars\.VERJSON_LANE_FALLBACK|ubuntu-[A-Za-z0-9]", re.I)

# R3's ceiling. Not a presence check: `timeout-minutes: 360` satisfies "has a
# timeout" while being exactly the runaway the requirement exists to prevent —
# six hours at macOS's 10x multiplier is up to 3,600 billable minutes from one
# hung step. The lanes are configured at 45; 60 is the reviewed ceiling.
HOSTED_TIMEOUT_CEILING = 60

# R5's sanctioned desktop-release path, as an EXPLICIT constant rather than an
# implicit absence. In `Verjson/.github` the set is empty and that is the whole
# rule: no workflow here may name an OS lane variable at all. `.github`
# deliberately does not grow a cross-platform release workflow — ADR 0060 retired
# `node-release.yml`, and the canonical path is a dispatched
# `changelog-release.yml` that builds nothing.
#
# `--sanctioned` appends to this set, which is how #815 points the same script at
# a consumer checkout whose desktop-release workflow is legitimately sanctioned.
# That is a parameter and not a hole in the guarantee: R1 and R2 take no exception
# from it, and the OS lane variables are repository-scoped, so a repository that
# sanctions a filename it does not own still resolves them to empty. R5 is a
# legibility rule — one grep that answers "who can spend hosted minutes" — layered
# on top of that containment, not the containment itself. It is deliberately NOT
# `github.repository == 'Verjson/AiB'`: hardcoding the consumer's name here would
# make a second desktop repository a pull request in this repository instead of a
# variable edit, which is the property ADR 0041 exists to preserve.
SANCTIONED_OS_LANE_WORKFLOWS: tuple[str, ...] = ()

# A workflow file this large is not a workflow. The cap bounds the obvious
# resource exhaustion, but note what it does NOT bound: a YAML alias bomb is
# roughly a kilobyte on disk and expands without limit, so the size cap would let
# it straight through. Anchors are refused separately below, which is the guard
# that actually addresses that class.
MAX_WORKFLOW_BYTES = 1024 * 1024


class Undetermined(Exception):
    """The sweep could not decide. Never rendered as clean."""


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------


class _LinedDict(dict):
    """A mapping that remembers the source line of each of its keys."""

    __slots__ = ("lines",)


class PolicyLoader(yaml.SafeLoader):
    """SafeLoader, plus key line numbers, minus anchors.

    `SafeLoader` is not decoration: #815 points this script at consumer
    checkouts, so it parses workflow files authored by an untrusted pull request.
    `yaml.load` with the default loader would let a tag directive construct
    arbitrary Python objects on a runner. Only `safe_load` semantics are used
    here, and this subclass narrows them further rather than widening them.
    """


def _construct_lined_map(loader: PolicyLoader, node: yaml.MappingNode):
    data = _LinedDict()
    data.lines = {}
    yield data
    data.update(loader.construct_mapping(node))
    data.lines = {
        key.value: key.start_mark.line + 1
        for key, _ in node.value
        if isinstance(key, yaml.ScalarNode)
    }


PolicyLoader.add_constructor("tag:yaml.org,2002:map", _construct_lined_map)


def _refuse_alias(self, node):  # noqa: ANN001 - PyYAML hook signature
    raise yaml.YAMLError(
        "YAML anchors and aliases are refused: GitHub Actions does not support "
        "them in workflows, and their expansion is unbounded"
    )


PolicyLoader.compose_node_original = yaml.SafeLoader.compose_node


def _compose_node(self, parent, index):  # noqa: ANN001 - PyYAML hook signature
    if self.check_event(yaml.events.AliasEvent):
        _refuse_alias(self, None)
    return PolicyLoader.compose_node_original(self, parent, index)


PolicyLoader.compose_node = _compose_node


def load_workflow(path: str) -> _LinedDict:
    """Return the single workflow document, or raise Undetermined.

    Every anomaly below is refused rather than skipped. "I could not read this
    file" is not "this file is clean", and the whole value of this check is that
    the difference is visible in the exit code.
    """
    try:
        size = os.path.getsize(path)
    except OSError as error:
        raise Undetermined(f"{path}: cannot stat: {error}") from error
    if size > MAX_WORKFLOW_BYTES:
        raise Undetermined(
            f"{path}: {size} bytes exceeds the {MAX_WORKFLOW_BYTES}-byte ceiling"
        )
    try:
        with open(path, encoding="utf-8") as stream:
            documents = list(yaml.load_all(stream, Loader=PolicyLoader))
    except (yaml.YAMLError, UnicodeDecodeError, OSError) as error:
        detail = " ".join(str(error).split())
        raise Undetermined(f"{path}: cannot parse: {detail}") from error

    if len(documents) != 1:
        # GitHub reads the first document. A reader that silently takes one of
        # several is guessing, and the metered selector can live in the other.
        raise Undetermined(
            f"{path}: expected exactly one YAML document, found {len(documents)}"
        )
    document = documents[0]
    if not isinstance(document, dict):
        raise Undetermined(f"{path}: top level is not a mapping")
    return document


def extract_jobs(path: str, document: dict) -> list[tuple[str, dict, int]]:
    """Return (name, body, line) per job, or raise Undetermined.

    Per FILE, deliberately. A global "did anything parse" counter only fires when
    NOTHING parses, so one unreadable file among readable siblings was silently
    ignored — the amplifier that turned an unscanned file into exit 0.
    """
    if "jobs" not in document:
        raise Undetermined(f"{path}: no 'jobs' key")
    jobs = document["jobs"]
    if not isinstance(jobs, dict):
        raise Undetermined(f"{path}: 'jobs' is not a mapping")
    if not jobs:
        raise Undetermined(f"{path}: 'jobs' is empty")
    lines = getattr(jobs, "lines", {})
    records = []
    for name, body in jobs.items():
        if not isinstance(body, dict):
            raise Undetermined(f"{path}: job '{name}' is not a mapping")
        records.append((str(name), body, lines.get(name, 0)))
    return records


def flatten(value) -> str:
    """Render any YAML value as searchable text.

    Structural rather than textual, so the shape a selector is written in stops
    mattering: `macos-15`, `[macos-15]`, a block sequence, and
    `{group: desktop, labels: [macos-15]}` — a real GitHub runner-group selector —
    all reduce to the same text.
    """
    if value is None:
        return ""
    if isinstance(value, dict):
        return " ".join(
            f"{flatten(key)} {flatten(item)}" for key, item in value.items()
        )
    if isinstance(value, (list, tuple)):
        return " ".join(flatten(item) for item in value)
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


EXPRESSION = re.compile(r"\$\{\{.*?\}\}", re.S)


def outside_expressions(text: str) -> str:
    """Drop every `${{ … }}` span, leaving the literal text around them."""
    return EXPRESSION.sub(" ", text)


# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------


class Report:
    def __init__(self) -> None:
        self.violations: list[str] = []
        self.anomalies: list[str] = []

    def violation(self, path: str, line: int, message: str) -> None:
        self.violations.append(f"{path}:{line}: {message}")

    def anomaly(self, message: str) -> None:
        self.anomalies.append(f"UNDETERMINED: {message}")


def check_job(report: Report, path: str, name: str, body: dict, line: int,
              visibility: str) -> None:
    if "runs-on" not in body:
        # A job-level `uses:` calls a reusable workflow and declares no runner of
        # its own; the requirement belongs to the called workflow.
        return
    lines = getattr(body, "lines", {})
    runs_on_line = lines.get("runs-on", line)
    timeout_line = lines.get("timeout-minutes", runs_on_line)

    runs_on = flatten(body["runs-on"])

    # EVERY rule below judges `selector`, never `runs_on`. That divergence
    # produced a live false negative once already: with the lane variable in
    # `strategy.matrix` — the shape #810 proposes and AiB will adopt — the
    # OS-lane test read `runs-on` alone, matched nothing, and skipped R3 and R4
    # entirely on the one workflow they were written for.
    #
    # Known imprecision, chosen deliberately: the WHOLE strategy block is folded
    # in, not only the key the selector references, so a metered word in an
    # unreferenced cross-compile key is refused too. Resolving the reference
    # precisely means re-implementing matrix semantics, and a bug there would
    # fail OPEN. A false positive costs an argument and is fixed by renaming a
    # key; a false negative costs money. Pinned by `matrix-unreferenced-key`.
    selector = runs_on
    if "matrix." in runs_on:
        selector = f"{runs_on} {flatten(body.get('strategy'))}"

    if METERED_FAMILY.search(selector):
        report.violation(
            path, runs_on_line,
            f"R1 metered hosted runner family in job '{name}' runs-on: {runs_on}",
        )

    # R2 — a rolling image inside a metered family. R1 already refuses the
    # selector, so this message is the point: R1 asks whether the org may spend
    # here at all, R2 whether a signed installer's build environment can change
    # without a commit. Keeping them distinct stops `macos-latest` ->
    # `windows-latest` reading as a fix.
    if METERED_LATEST.search(selector):
        report.violation(
            path, runs_on_line,
            f"R2 rolling -latest image in job '{name}' runs-on: {runs_on}",
        )

    # Tier B — literal Linux hosted selectors, keyed on repository visibility.
    #
    # Hosted minutes are FREE for a public repository (measured 2026-08-01; ADR
    # 0047 corrected ADR 0033's "unfunded" premise), so `ubuntu-latest` there
    # spends nothing. On a private repository the same line rides the spending
    # limit #810 is raising.
    #
    # Asked of the text OUTSIDE every expression span. Inside a `${{ … }}` chain,
    # `'["ubuntu-24.04"]'` is ADR 0040's portability tail, which appears in the
    # generated caller of every consumer and which runner-routing-policy.test.sh
    # already strips; firing on it would reject ~89 conforming repositories, and
    # a check nobody can keep switched on enforces nothing. But `${{ matrix.os }}`
    # with `os: [ubuntu-24.04]` IS a hardcoded selector wearing an indirection,
    # and stripping the expression rather than skipping the job is what catches
    # it. The public-repository half of this rule — a literal should still use
    # `vars.VERJSON_RUNNER_FASTLANE`, a variable, so capacity moves stay
    # org-variable edits (ADR 0041) — is #816, deferred by decision.
    if visibility == "private" and LINUX_HOSTED_LITERAL.search(
        outside_expressions(selector)
    ):
        report.violation(
            path, runs_on_line,
            f"TierB literal Linux hosted selector on a private repository in job "
            f"'{name}' — use vars.VERJSON_RUNNER_FASTLANE or a lane variable: {runs_on}",
        )

    if not OS_LANE.search(selector):
        # R4, the ordinary half. A placement chain must have a terminal landing —
        # `VERJSON_LANE_FALLBACK`, or the portable `'["ubuntu-24.04"]'` tail ADR
        # 0040 put there for an organization with no lane variables at all. A
        # chain that stops at its own variable leaves an org that set only the
        # fallback with an EMPTY `runs-on`, and GitHub does not fail an
        # unplaceable job — it queues it forever with no diagnostic (#401).
        #
        # "Has a terminal landing" rather than "names FALLBACK", so node-ci.yml's
        # ADR 0086 secretless acquisition job — deliberately
        # `VERJSON_LANE_UNTRUSTED || '["ubuntu-24.04"]'`, never the trusted
        # fallback — is covered by the rule instead of by a repository-specific
        # carve-out this script would have to carry into ~89 consumers.
        if PLACEMENT_VARIABLE.search(selector) and not TERMINAL_LANDING.search(selector):
            report.violation(
                path, runs_on_line,
                f"R4 lane selector with no terminal landing in job '{name}' — it "
                f"resolves to an empty runs-on when the variable is unset: {runs_on}",
            )
        return

    # R4 — the OS lanes are the exception, and it runs the other way. They must
    # NOT chain to VERJSON_LANE_FALLBACK, and must not carry the portable
    # `'["ubuntu-…"]'` tail either: both degrade a macOS or Windows leg onto
    # Linux, producing a non-installable artifact behind a green check. Failing
    # closed is louder and cheaper than shipping the wrong binary.
    if TERMINAL_LANDING.search(selector):
        report.violation(
            path, runs_on_line,
            f"R4 OS lane carries a fallback tail in job '{name}' — an unset OS "
            f"lane must fail closed, never degrade to Linux: {runs_on}",
        )

    # R3 — bounded, not merely annotated. Missing key and over-ceiling value are
    # separate messages because they are separate mistakes: one is a job nobody
    # bounded, the other a bound somebody chose too high.
    timeout = body.get("timeout-minutes")
    if timeout is None:
        report.violation(
            path, runs_on_line,
            f"R3 OS-lane job declares no timeout-minutes in job '{name}'",
        )
    elif isinstance(timeout, bool) or not isinstance(timeout, int):
        # An expression or a non-integer cannot be compared against the ceiling,
        # so it is refused rather than skipped: an unevaluatable bound is not a
        # bound, and skipping it is how `timeout-minutes: ${{ inputs.timeout }}`
        # would buy back the whole six-hour default through a caller's value.
        report.violation(
            path, timeout_line,
            f"R3 OS-lane timeout-minutes is not a literal integer in job "
            f"'{name}': {timeout}",
        )
    elif timeout > HOSTED_TIMEOUT_CEILING:
        report.violation(
            path, timeout_line,
            f"R3 OS-lane timeout-minutes {timeout} exceeds the "
            f"{HOSTED_TIMEOUT_CEILING} ceiling in job '{name}'",
        )


def check_os_lane_references(report: Report, path: str, sanctioned: set[str]) -> None:
    """R5 — a file-wide TEXT scan, deliberately independent of the parser.

    Every other rule depends on resolving the document; this one must hold even
    for a file the parser refuses, and it is the rule that answers "who can spend
    hosted minutes" with one grep. A reference in a comment counts: a
    commented-out selector is a copy-paste away from a live one, which is exactly
    how this defect class regrew four times (#175, #182, #192, #203).
    """
    if os.path.basename(path) in sanctioned:
        return
    try:
        with open(path, encoding="utf-8", errors="replace") as stream:
            for number, text in enumerate(stream, start=1):
                if OS_LANE_TEXT.search(text):
                    report.violation(
                        path, number,
                        "R5 off-path reference to an OS lane variable — only the "
                        "sanctioned desktop-release path may name "
                        "VERJSON_LANE_TRUSTED_MACOS or VERJSON_LANE_TRUSTED_WINDOWS",
                    )
    except OSError as error:
        report.anomaly(f"{path}: cannot read: {error}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


class _ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str):  # noqa: D102 - argparse hook
        raise Undetermined(message)


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = _ArgumentParser(add_help=False)
    # No default. A caller that does not say what it is scanning gets no verdict,
    # because a permissive default here silently disables Tier B.
    parser.add_argument("--visibility", action="append")
    # Behind a flag, not a trailing positional: in a script that fails closed
    # everywhere else, a stray argument must not quietly sanction a file and
    # narrow the sweep.
    parser.add_argument("--sanctioned", action="append", default=[])
    parser.add_argument("workflow_dir", nargs="?")
    parser.add_argument("extra", nargs="*")
    arguments = parser.parse_args(argv)

    if arguments.extra:
        raise Undetermined(
            f"unexpected argument(s): {' '.join(arguments.extra)} "
            "(sanctioned workflows go behind --sanctioned)"
        )
    visibility = arguments.visibility or []
    if len(visibility) > 1:
        # Last-wins on a repeated flag is how a caller typo silently changes the
        # policy tier being enforced.
        raise Undetermined(f"--visibility given {len(visibility)} times")
    arguments.visibility = visibility[0] if visibility else ""
    if arguments.visibility not in ("public", "private"):
        raise Undetermined(
            "--visibility must be exactly 'public' or 'private' "
            f"(got '{arguments.visibility}')"
        )
    if not arguments.workflow_dir:
        raise Undetermined("no workflow directory given")
    return arguments


def collect_workflow_files(workflow_dir: str) -> list[str]:
    if not os.path.isdir(workflow_dir):
        raise Undetermined(f"not a directory: {workflow_dir}")
    # Both suffixes. GitHub runs `.yaml` and `.yml` identically, and a sweep that
    # globs `*.yml` alone is evaded by renaming the file (#401).
    files = sorted(
        os.path.join(workflow_dir, entry)
        for entry in os.listdir(workflow_dir)
        if entry.endswith((".yml", ".yaml"))
        and os.path.isfile(os.path.join(workflow_dir, entry))
    )
    if not files:
        # A sweep that scans nothing must not look like a sweep that found
        # nothing: a deleted directory, a renamed path in a consumer checkout, or
        # a typo in the #815 caller would otherwise report green.
        raise Undetermined(
            f"no .yml or .yaml workflow files found under {workflow_dir}"
        )
    return files


def main(argv: list[str]) -> int:
    try:
        arguments = parse_arguments(argv)
        workflow_files = collect_workflow_files(arguments.workflow_dir)
    except Undetermined as error:
        print(f"UNDETERMINED: {error}", file=sys.stderr)
        return 2

    sanctioned = set(SANCTIONED_OS_LANE_WORKFLOWS) | set(arguments.sanctioned)
    report = Report()

    for path in workflow_files:
        check_os_lane_references(report, path, sanctioned)
        try:
            document = load_workflow(path)
            jobs = extract_jobs(path, document)
        except Undetermined as error:
            report.anomaly(str(error))
            continue
        for name, body, line in jobs:
            check_job(report, path, name, body, line, arguments.visibility)

    for message in report.anomalies:
        print(message, file=sys.stderr)
    for message in report.violations:
        print(message, file=sys.stderr)

    # A definite violation is reported as one; otherwise an incomplete sweep is
    # undetermined. Both are non-zero, so neither can be mistaken for clean, and
    # there is no path to green that leaves either unaddressed.
    if report.violations:
        return 1
    if report.anomalies:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
