# Repository hygiene

Baseline hygiene for every Verjson repository: the default branch carries a root
`README.md` that answers what the repository is for, who owns it, and how to
validate it locally. The decision, the exact rule and its known limits are in
[ADR 0045](../decisions/0045-baseline-repository-hygiene/README.md).

Hygiene is **baseline CI**. A green check means a reader can orient themselves in
the repository; it is never evidence that the repository's own behaviour works,
and never a substitute for repository-specific build, test, or config validation.

## What lives here

| File | What it is |
| --- | --- |
| [`README.template.md`](README.template.md) | The README a new repository is seeded with. It passes the check, and a test asserts that. |
| [`exemptions.tsv`](exemptions.tsv) | The only place an exemption can be granted. |

The check itself is [`scripts/repo-hygiene.sh`](../../scripts/repo-hygiene.sh),
covered by `scripts/repo-hygiene.test.sh` and published as the reusable workflow
[`repo-hygiene.yml`](../../.github/workflows/repo-hygiene.yml).

## Adopting it

Add one job alongside the repository's own CI — its domain CI still does the real
work:

```yaml
jobs:
  hygiene:
    uses: Verjson/.github/.github/workflows/repo-hygiene.yml@v2
    with:
      hygiene_ref: <immutable Verjson/.github commit>
```

`mode` defaults to `audit`: findings are reported and the job stays green. Flip a
repository to `mode: enforce` once its backlog is clear.

## Running it locally

```bash
bash scripts/repo-hygiene.sh --repo-root . --repository Verjson/<name>
bash scripts/repo-hygiene.sh --repo-root . --mode enforce   # what enforcement would say
```

It reads the git **tree**, not the working directory, so commit a fix before
re-running it.

## Asking for an exemption

Open a pull request here adding one tab-separated row to `exemptions.tsv`:
repository, class (`archived`, `mirror`, `generated`, `bootstrap`), a review-by
date, and a reason a reviewer can check. There is no way for a repository to
exempt itself — that is the point of the register, not an oversight — and every
row expires, so a grant nobody re-reads returns to the backlog.
