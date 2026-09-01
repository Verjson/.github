/**
 * Normalizes `npm pack --json` output across the shapes npm has emitted.
 *
 * npm 11 and earlier return an array of packed entries; npm 12 returns an
 * object keyed by package name. Reading `[0].filename` silently yields
 * `undefined` on the object shape, which surfaces much later as an unresolvable
 * specifier, so every unexpected shape fails closed here instead.
 */
export function resolvePackedTarball(stdout, expectedName) {
  if (typeof expectedName !== 'string' || expectedName === '') {
    throw new Error('expected npm package name is required');
  }

  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch (cause) {
    throw new Error(`npm pack output is not valid JSON: ${stdout}`, { cause });
  }

  const objectReceipt =
    !Array.isArray(parsed) && parsed !== null && typeof parsed === 'object';
  const objectKeys = objectReceipt ? Object.keys(parsed) : null;
  const entries = Array.isArray(parsed) ? parsed : objectReceipt ? Object.values(parsed) : null;
  if (entries === null) {
    throw new Error(`npm pack returned ${typeof parsed}, expected an array or object`);
  }
  if (entries.length === 0) {
    throw new Error('npm pack packed no tarball');
  }
  if (entries.length > 1) {
    // Choosing one here is how the wrong tarball gets installed unnoticed.
    throw new Error(
      `npm pack packed ${entries.length} tarballs, expected exactly one: ` +
        entries.map((entry) => entry?.filename ?? '<unnamed>').join(', '),
    );
  }
  if (objectReceipt && objectKeys[0] !== expectedName) {
    throw new Error(
      `npm pack receipt is keyed by ${objectKeys[0]}, expected ${expectedName}`,
    );
  }

  const [entry] = entries;
  const { filename, name } = entry ?? {};
  if (typeof filename !== 'string' || filename === '') {
    throw new Error(`npm pack entry has no filename: ${JSON.stringify(entry)}`);
  }
  if (!filename.endsWith('.tgz')) {
    throw new Error(`npm pack filename is not a tarball: ${filename}`);
  }
  // The filename is joined onto the pack destination, so it must stay inside it.
  if (filename !== basenameOf(filename)) {
    throw new Error(`npm pack filename is not a bare file name: ${filename}`);
  }
  if (name !== expectedName) {
    throw new Error(`npm pack produced a tarball for ${name}, expected ${expectedName}`);
  }

  return entry;
}

function basenameOf(filename) {
  return filename.split(/[/\\]/).at(-1);
}
