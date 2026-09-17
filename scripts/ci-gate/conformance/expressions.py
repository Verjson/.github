#!/usr/bin/env python3
"""A restricted evaluator for the GitHub expression subset used in `if:` guards.

The point of this module is what it *refuses* to do. A conformance harness that
guesses `false` for an expression it does not understand reports every guarded
step as skipped, and a suite built on that asserts nothing while looking
thorough — the same shape of failure as `Verjson/verjson-ci#184`, where a job
reported success having executed nothing. So every construct is either
implemented exactly or raises `UnsupportedExpression`, and the caller is
expected to let that propagate.
"""

from __future__ import annotations

import ast
import re


class UnsupportedExpression(Exception):
    """A guard uses a construct this evaluator does not implement.

    Raised rather than approximated: an approximated guard silently changes
    which steps the harness believes ran.
    """


class UnknownContext(Exception):
    """A guard reads a context value the scenario does not bind.

    A scenario that forgets to bind an input must fail loudly, not inherit a
    default that happens to make the assertion pass.
    """


# GitHub expression -> Python, for the operators this contract actually uses.
_OPERATORS = (
    ('&&', ' and '),
    ('||', ' or '),
    ('!==', None),   # not a GitHub operator; catch a JS habit rather than mistranslate
)

_FUNCTION_CALL = re.compile(r'\b(?P<name>[a-zA-Z][a-zA-Z0-9_-]*)\s*\(')
_CONTEXT_REF = re.compile(
    r'\b(?:needs|inputs|steps|github|runner|env|vars|matrix|secrets)\b'
    r'(?:\.[A-Za-z0-9_-]+)+')

_SUPPORTED_FUNCTIONS = {'always', 'success', 'failure', 'cancelled', 'hashFiles'}

# Known divergence: GitHub compares strings case-insensitively and this does
# not. Matching it would make a guard comparing against the wrong casing
# evaluate as intended here and fail in Actions — the harness would hide the
# defect. No guard in the contract depends on the difference; a guard that
# starts to should be rewritten rather than accommodated.


def _python_source(expression: str, placeholders: dict[str, str]) -> str:
    source = expression
    for github_op, python_op in _OPERATORS:
        if python_op is None:
            if github_op in source:
                raise UnsupportedExpression(f'{github_op!r} is not a GitHub operator')
            continue
        source = source.replace(github_op, python_op)
    # `!x` is GitHub's negation; Python needs `not x`. Do this after the binary
    # operators so `!=` has already been consumed by neither replacement.
    source = re.sub(r'!(?!=)', ' not ', source)
    for name, placeholder in placeholders.items():
        source = source.replace(name, placeholder)
    return source


class Evaluator:
    """Evaluates one workflow's guards against one scenario's bindings."""

    def __init__(self, bindings: dict[str, object], *, functions: dict[str, object] | None = None):
        self.bindings = bindings
        self.functions = functions or {}

    def evaluate(self, expression: str | bool | None) -> bool:
        if expression is None:
            return True
        if isinstance(expression, bool):
            return expression
        expression = str(expression).strip()
        if expression.startswith('${{') and expression.endswith('}}'):
            expression = expression[3:-2].strip()

        placeholders: dict[str, str] = {}
        values: dict[str, object] = {}

        for match in _FUNCTION_CALL.finditer(expression):
            name = match.group('name')
            if name not in _SUPPORTED_FUNCTIONS:
                raise UnsupportedExpression(f'unsupported function {name}()')

        for index, name in enumerate(sorted(set(_CONTEXT_REF.findall(expression)),
                                            key=len, reverse=True)):
            if name not in self.bindings:
                raise UnknownContext(name)
            placeholder = f'_ctx{index}'
            placeholders[name] = placeholder
            values[placeholder] = self.bindings[name]

        source = _python_source(expression, placeholders)
        for name in _SUPPORTED_FUNCTIONS:
            if name in self.functions:
                values[name] = self.functions[name]
        # GitHub's boolean and null literals are lowercase, so they reach the
        # parser as names rather than as Python constants.
        values.setdefault('true', True)
        values.setdefault('false', False)
        values.setdefault('null', None)

        try:
            tree = ast.parse(source, mode='eval')
        except SyntaxError as error:
            raise UnsupportedExpression(f'{expression!r} -> {source!r}: {error}') from error

        self._reject_unsupported_nodes(tree, expression, values)
        return bool(eval(compile(tree, '<guard>', 'eval'), {'__builtins__': {}}, values))

    @staticmethod
    def _reject_unsupported_nodes(tree: ast.Expression, expression: str,
                                  values: dict[str, object]) -> None:
        allowed = (
            ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.UnaryOp, ast.Not,
            ast.Compare, ast.Eq, ast.NotEq, ast.Name, ast.Load, ast.Constant,
            ast.Call,
        )
        for node in ast.walk(tree):
            if not isinstance(node, allowed):
                raise UnsupportedExpression(
                    f'{expression!r} contains unsupported {type(node).__name__}')
            # An unbound name would reach `eval` and raise a bare NameError,
            # which is outside this module's typed-error contract and reads to
            # a caller as a harness crash rather than as an unmodelled guard.
            if isinstance(node, ast.Name) and node.id not in values:
                raise UnsupportedExpression(
                    f'{expression!r} reads {node.id!r}, which nothing bound')
