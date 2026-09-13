import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';

import {
  cacheKeyForDir,
  getCachePath,
  getFreshnessKey,
  loadCachedIndex,
  handleFindFiles,
  handleFindDefinition,
  handleGetOutline,
  updateFileInCache,
  findProjectDir,
  CACHE_DIR
} from '../index.js';

test('cacheKeyForDir computes deterministic sha1 hex digest', () => {
  const dir = '/workspace/test-repo';
  const expected = crypto.createHash('sha1').update(dir).digest('hex');
  assert.equal(cacheKeyForDir(dir), expected);
  assert.equal(cacheKeyForDir(dir), cacheKeyForDir(dir));
});

test('getCachePath joins CACHE_DIR and hash.json', () => {
  const dir = '/workspace/test-repo';
  const key = cacheKeyForDir(dir);
  const expected = path.join(CACHE_DIR, `${key}.json`);
  assert.equal(getCachePath(dir), expected);
});

test('getFreshnessKey detects git repository state or returns null for non-git', () => {
  // Current repo should have valid commit hash and status
  const currentRepoKey = getFreshnessKey(process.cwd());
  assert.ok(typeof currentRepoKey === 'string' && currentRepoKey.includes(':'));

  // Temporary non-git directory returns null
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'code-intel-non-git-'));
  try {
    assert.equal(getFreshnessKey(tempDir), null);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test('loadCachedIndex returns null when cache file does not exist', () => {
  const dummyDir = '/tmp/nonexistent-project-' + Date.now();
  assert.equal(loadCachedIndex(dummyDir), null);
});

test('loadCachedIndex loads tags when cache is fresh and rejects when stale', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'code-intel-cache-test-'));
  const cachePath = getCachePath(tempDir);
  const cacheDir = path.dirname(cachePath);

  try {
    fs.mkdirSync(cacheDir, { recursive: true });

    const testTags = [
      { name: 'UserService', kind: 'class', path: path.join(tempDir, 'user.js'), line: 10 }
    ];
    fs.writeFileSync(cachePath, JSON.stringify({ freshnessKey: null, tags: testTags }));

    assert.equal(loadCachedIndex(tempDir), null);

    const currentFreshness = getFreshnessKey(process.cwd());
    if (currentFreshness) {
      const repoCachePath = getCachePath(process.cwd());
      const originalCache = fs.existsSync(repoCachePath) ? fs.readFileSync(repoCachePath, 'utf8') : null;

      try {
        fs.writeFileSync(repoCachePath, JSON.stringify({
          freshnessKey: currentFreshness,
          tags: testTags
        }));

        const loaded = loadCachedIndex(process.cwd());
        assert.ok(Array.isArray(loaded));
        assert.equal(loaded.length, 1);
        assert.equal(loaded[0].name, 'UserService');

        // Stale test: changed freshnessKey
        fs.writeFileSync(repoCachePath, JSON.stringify({
          freshnessKey: 'stale-hash:0',
          tags: testTags
        }));
        assert.equal(loadCachedIndex(process.cwd()), null);
      } finally {
        if (originalCache !== null) {
          fs.writeFileSync(repoCachePath, originalCache);
        } else if (fs.existsSync(repoCachePath)) {
          fs.unlinkSync(repoCachePath);
        }
      }
    }
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
    if (fs.existsSync(cachePath)) {
      fs.unlinkSync(cachePath);
    }
  }
});

test('handleFindFiles finds files in project directory', () => {
  const res = handleFindFiles({ path: process.cwd(), query: 'package.json' });
  assert.ok(!res.error);
  assert.match(res.text, /package\.json/);
});

test('handleFindDefinition validates input', () => {
  const resMissing = handleFindDefinition({});
  assert.equal(resMissing.error, 'Symbol parameter is required');

  const resNotFound = handleFindDefinition({ symbol: 'NonExistentSymbol12345XYZ', path: process.cwd() });
  assert.ok(!resNotFound.error);
  assert.match(resNotFound.text, /No definition found/);
});

test('handleGetOutline validates file existence', () => {
  const resMissing = handleGetOutline({ path: '/tmp/nonexistent-outline-file.js' });
  assert.ok(resMissing.error);
  assert.match(resMissing.error, /File not found/i);
});

test('updateFileInCache updates cached tags for specific file', () => {
  const repoRoot = findProjectDir(process.cwd());
  const cachePath = getCachePath(repoRoot);
  const cacheDir = path.dirname(cachePath);
  fs.mkdirSync(cacheDir, { recursive: true });

  const originalCache = fs.existsSync(cachePath) ? fs.readFileSync(cachePath, 'utf8') : null;
  const dummyFile = path.join(repoRoot, 'dummy-test-file.js');

  try {
    const initialTags = [
      { name: 'ExistingSymbol', kind: 'function', path: path.join(repoRoot, 'other.js'), line: 5 },
      { name: 'OldDummySymbol', kind: 'function', path: dummyFile, line: 1 }
    ];
    fs.writeFileSync(cachePath, JSON.stringify({
      freshnessKey: getFreshnessKey(repoRoot),
      tags: initialTags
    }));

    const newFileTags = [
      { name: 'NewDummySymbol1', kind: 'class', line: 10 },
      { name: 'NewDummySymbol2', kind: 'method', line: 20 }
    ];

    updateFileInCache(dummyFile, newFileTags);

    const updated = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
    assert.equal(updated.tags.length, 3);
    assert.ok(updated.tags.some(t => t.name === 'ExistingSymbol'));
    assert.ok(!updated.tags.some(t => t.name === 'OldDummySymbol'));
    assert.ok(updated.tags.some(t => t.name === 'NewDummySymbol1' && t.line === 10));
    assert.ok(updated.tags.some(t => t.name === 'NewDummySymbol2' && t.line === 20));
  } finally {
    if (originalCache !== null) {
      fs.writeFileSync(cachePath, originalCache);
    } else if (fs.existsSync(cachePath)) {
      fs.unlinkSync(cachePath);
    }
  }
});
