# Parse Node version components as decimal — 2026-07-21

Normalize numeric Node version components to base 10 before evaluating the
semantic-release engine floor, so zero-padded input receives the intended clear
diagnostic instead of a Bash octal-parsing error. Fixes #101.
