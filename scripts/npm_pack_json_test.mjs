import assert from 'node:assert/strict';
import test from 'node:test';

import { resolvePackedTarball } from './npm-pack-json.mjs';

const expectedName = '@verjson/example';
const filename = 'verjson-example-1.2.3.tgz';
const receipt = { name: expectedName, filename };

test('accepts the npm 11 array receipt', () => {
  assert.deepEqual(resolvePackedTarball(JSON.stringify([receipt]), expectedName), receipt);
});

test('accepts the npm 12 package-keyed object receipt', () => {
  assert.deepEqual(
    resolvePackedTarball(JSON.stringify({ [expectedName]: receipt }), expectedName),
    receipt,
  );
});

for (const missingName of [undefined, '']) {
  test(`rejects omitted expected package identity ${JSON.stringify(missingName)}`, () => {
    assert.throws(
      () => resolvePackedTarball(JSON.stringify([receipt]), missingName),
      /expected npm package name is required/,
    );
  });
}

for (const [behavior, value, message] of [
  ['invalid JSON', '{', /not valid JSON/],
  ['a scalar receipt', 'null', /expected an array or object/],
  ['no tarballs', '[]', /packed no tarball/],
  ['an empty object', '{}', /packed no tarball/],
  ['multiple tarballs', JSON.stringify([receipt, receipt]), /packed 2 tarballs/],
  ['a missing filename', JSON.stringify([{ name: expectedName }]), /has no filename/],
  ['a non-tarball filename', JSON.stringify([{ name: expectedName, filename: 'package.zip' }]), /not a tarball/],
  ['a forward-slash path', JSON.stringify([{ name: expectedName, filename: `nested/${filename}` }]), /not a bare file name/],
  ['a backslash path', JSON.stringify([{ name: expectedName, filename: `nested\\${filename}` }]), /not a bare file name/],
  ['a different package', JSON.stringify([{ name: '@verjson/other', filename }]), /tarball for @verjson\/other/],
]) {
  test(`rejects ${behavior}`, () => {
    assert.throws(() => resolvePackedTarball(value, expectedName), message);
  });
}

test('rejects an npm 12 receipt whose object key is not the expected package', () => {
  assert.throws(
    () => resolvePackedTarball(JSON.stringify({ '@verjson/other': receipt }), expectedName),
    /receipt is keyed by @verjson\/other/,
  );
});

test('rejects an npm 12 receipt whose entry name disagrees with its package key', () => {
  assert.throws(
    () => resolvePackedTarball(
      JSON.stringify({ [expectedName]: { ...receipt, name: '@verjson/other' } }),
      expectedName,
    ),
    /tarball for @verjson\/other/,
  );
});
