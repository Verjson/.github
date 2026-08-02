// Runs the locked semantic-release and reports whether it actually published,
// so a caller can gate follow-up work on a real publication instead of on job
// success — semantic-release exits 0 when no release is necessary (#244).
//
// Uses the programmatic API rather than the `semantic-release` CLI because the
// API returns a structured result (`false`, or `{ nextRelease, ... }`). The CLI
// only reports the outcome in its log text, and parsing that would tie this
// workflow's published contract to semantic-release's log format. Resolution is
// still lockfile-backed: this file is copied into the tooling directory next to
// the `npm ci --ignore-scripts` tree, so the import below resolves there.
import { appendFileSync } from 'node:fs';
import semanticRelease from 'semantic-release';

const outputPath = process.env.GITHUB_OUTPUT;
if (!outputPath) {
  throw new Error('GITHUB_OUTPUT is unset; refusing to publish without anywhere to report the result');
}

// Anything thrown from here exits non-zero and leaves both step outputs unset.
// A caller comparing against 'true' therefore reads a failed or half-finished
// release as "not published", which is the safe direction for a gate that
// triggers irreversible follow-up work.
const result = await semanticRelease();

let published = 'false';
let version = '';

if (result !== false) {
  version = result?.nextRelease?.version;
  // A truthy result without a usable version means the API's shape changed
  // under the pin. Fail loudly rather than reporting a publication we cannot
  // name, or degrading to 'false' — a guard that quietly downgrades is how a
  // fail-closed contract turns into a fail-open one.
  if (typeof version !== 'string' || version === '') {
    throw new Error(
      `semantic-release reported a release with no usable version: ${JSON.stringify(result?.nextRelease)}`,
    );
  }
  published = 'true';
}

appendFileSync(outputPath, `new-release-published=${published}\nnew-release-version=${version}\n`);
