import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '..', '..');
const maskerCommand = path.join(repositoryRoot, 'masker');

test('prints self-contained MCP setup details without a remote instruction URL', () => {
  const result = spawnSync(maskerCommand, ['mcp', 'info'], {
    cwd: repositoryRoot,
    encoding: 'utf8'
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Privacy boundary:/);
  assert.match(result.stdout, /\.\/masker mcp install codex/);
  assert.match(result.stdout, /\.\/masker mcp install claude/);
  assert.match(result.stdout, /does not fetch remote instructions/);
  assert.doesNotMatch(result.stdout, /https?:\/\//);
});

test('rejects an unknown MCP host without installing anything', () => {
  const result = spawnSync(maskerCommand, ['mcp', 'install', 'unknown-host'], {
    cwd: repositoryRoot,
    encoding: 'utf8'
  });

  assert.equal(result.status, 2);
  assert.match(result.stderr, /Unknown MCP host/);
});
