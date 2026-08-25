import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

const here = dirname(fileURLToPath(import.meta.url));
const serverPath = join(here, '..', 'src', 'index.mjs');

async function exercise(mode) {
  const store = await mkdtemp(join(tmpdir(), 'masker-mcp-protocol-'));
  const status = {
    format: 'masker-mcp-status',
    version: 1,
    revision: 2,
    state: 'ready',
    sessionID: 'session-protocol-test',
    phase: 'discovery',
    documentCount: 1,
    documents: [{ id: 'document-001', index: 1, state: 'unreviewed' }],
    activeDocumentID: 'document-001',
    activeDocumentIndex: 1,
    maskSetVersion: 1,
    reviewedCount: 0,
    staleCount: 0,
    exportedCount: 0,
    currentReviewed: false,
    currentScanned: false,
    matchCount: null,
    selectedMatchCount: null,
    busy: false,
    userActionRequired: 'scan_and_review_current_document'
  };
  await writeFile(join(store, 'mcp-status.json'), JSON.stringify(status));
  const options = mode === 'modern'
    ? { versionNegotiation: { mode: { pin: '2026-07-28' } } }
    : { versionNegotiation: { mode: 'legacy' } };
  const client = new Client({ name: `masker-${mode}-test`, version: '1.0.0' }, options);
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    env: { ...process.env, MASKER_PRIVATE_BATCH_DIRECTORY: store }
  });
  try {
    await client.connect(transport);
    assert.equal(client.getProtocolEra(), mode);
    const listed = await client.listTools();
    assert.ok(listed.tools.some(tool => tool.name === 'get_private_batch_status'));
    assert.ok(listed.tools.some(tool => tool.name === 'begin_private_batch'));
    const result = await client.callTool({ name: 'get_private_batch_status', arguments: {} });
    assert.equal(result.structuredContent.session_id, 'session-protocol-test');
    assert.equal(result.structuredContent.document_count, 1);
  } finally {
    await client.close();
    await rm(store, { recursive: true, force: true });
  }
}

test('serves the legacy 2025 MCP era', () => exercise('legacy'));
test('serves the stateless 2026-07-28 MCP era', () => exercise('modern'));
