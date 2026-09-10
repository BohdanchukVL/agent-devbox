import test from 'node:test';
import assert from 'node:assert/strict';
import {
  isPostgres,
  isLocalPostgresUrl,
  resolveConnection,
  truncateCell,
  formatMarkdownTable,
} from '../index.js';

test('isPostgres correctly identifies Postgres targets', () => {
  assert.equal(isPostgres('postgres://user:pass@host:5432/db'), true);
  assert.equal(isPostgres('postgresql://user:pass@host:5432/db'), true);
  assert.equal(isPostgres('mysql://user:pass@host:3306/db'), false);
  assert.equal(isPostgres('/path/to/file.db'), false);
  assert.equal(isPostgres(null), false);
  assert.equal(isPostgres(''), false);
});

test('isLocalPostgresUrl differentiates local vs remote hosts', () => {
  assert.equal(isLocalPostgresUrl('postgres://localhost/db'), true);
  assert.equal(isLocalPostgresUrl('postgresql://127.0.0.1:5432/db'), true);
  assert.equal(isLocalPostgresUrl('postgresql://[::1]:5432/db'), true);

  // LAN / mDNS .local domains are NOT treated as localhost for security
  assert.equal(isLocalPostgresUrl('postgres://myhost.local:5432/db'), false);
  assert.equal(isLocalPostgresUrl('postgres://ep-xyz.eu-central-1.aws.neon.tech/db'), false);
  assert.equal(isLocalPostgresUrl('postgresql://db.prod.company.com/db'), false);
  assert.equal(isLocalPostgresUrl('invalid-url'), false);
});

test('resolveConnection accepts explicit valid connections', () => {
  const remote = 'postgres://app:secret@db.external.com:5432/prod';
  const res = resolveConnection(remote);
  assert.equal(res.target, remote);
  assert.equal(res.error, undefined);

  const sqliteFile = 'data/test.sqlite';
  const resSqlite = resolveConnection(sqliteFile);
  assert.equal(resSqlite.target, sqliteFile);
});

test('resolveConnection blocks remote DATABASE_URL by default (security)', () => {
  const oldEnv = process.env.DATABASE_URL;
  const oldAllow = process.env.DEVBOX_DB_ALLOW_REMOTE;
  delete process.env.DEVBOX_DB_ALLOW_REMOTE;

  try {
    process.env.DATABASE_URL = 'postgres://user:pass@remote-rds.amazonaws.com:5432/app';
    const res = resolveConnection();
    assert.equal(res.target, null);
    assert.match(res.error, /remote auto-discovery is disabled for security/i);

    // Allowing remote via env flag works
    process.env.DEVBOX_DB_ALLOW_REMOTE = 'true';
    const resAllowed = resolveConnection();
    assert.equal(resAllowed.target, process.env.DATABASE_URL);
  } finally {
    if (oldEnv !== undefined) process.env.DATABASE_URL = oldEnv;
    else delete process.env.DATABASE_URL;
    if (oldAllow !== undefined) process.env.DEVBOX_DB_ALLOW_REMOTE = oldAllow;
    else delete process.env.DEVBOX_DB_ALLOW_REMOTE;
  }
});

test('resolveConnection allows local Postgres DATABASE_URL automatically', () => {
  const oldEnv = process.env.DATABASE_URL;
  delete process.env.DEVBOX_DB_ALLOW_REMOTE;

  try {
    process.env.DATABASE_URL = 'postgres://postgres:password@localhost:5432/testdb';
    const res = resolveConnection();
    assert.equal(res.target, process.env.DATABASE_URL);
    assert.equal(res.error, undefined);
  } finally {
    if (oldEnv !== undefined) process.env.DATABASE_URL = oldEnv;
    else delete process.env.DATABASE_URL;
  }
});

test('truncateCell respects MAX_CELL_BYTES limit and handles various types', () => {
  assert.equal(truncateCell(null), '`NULL`');
  assert.equal(truncateCell(undefined), '`NULL`');
  assert.equal(truncateCell(12345), '12345');
  assert.equal(truncateCell('normal text'), 'normal text');

  // Huge string truncation
  const huge = 'A'.repeat(5000);
  const truncated = truncateCell(huge, 100);
  assert.equal(truncated.startsWith('A'.repeat(100)), true);
  assert.match(truncated, /\[truncated 4900 bytes\]/);

  // Multi-byte Unicode & emoji truncation without broken characters
  const ukr = 'Привіт світ! '.repeat(20);
  const truncUkr = truncateCell(ukr, 50);
  const ukrPrefix = truncUkr.split('…')[0];
  assert.ok(Buffer.byteLength(ukrPrefix, 'utf8') <= 50);
  assert.equal(ukrPrefix.includes('\uFFFD'), false);

  const emojis = '🚀🎉🔥💡🛡️'.repeat(10);
  const truncEmoji = truncateCell(emojis, 30);
  const emojiPrefix = truncEmoji.split('…')[0];
  assert.ok(Buffer.byteLength(emojiPrefix, 'utf8') <= 30);
  assert.equal(emojiPrefix.includes('\uFFFD'), false);
});

test('formatMarkdownTable caps output bytes to prevent context blowout', () => {
  const headers = ['id', 'payload'];
  const rows = [];
  for (let i = 0; i < 50; i++) {
    rows.push({ id: i, payload: 'X'.repeat(200) });
  }

  // Small limit: 1000 bytes
  const md = formatMarkdownTable(headers, rows, 1000, 500);
  assert.match(md, /Output truncated/);
  assert.match(md, /Narrow your query with LIMIT/);
  assert.ok(Buffer.byteLength(md, 'utf8') < 2000);
});
