import assert from 'node:assert/strict';
import test from 'node:test';
import { commandIsReflected, safeStatus } from '../src/index.mjs';

function rawStatus() {
  return {
    format: 'masker-mcp-status',
    version: 1,
    revision: 9,
    state: 'ready',
    sessionID: 'session-test',
    phase: 'discovery',
    documentCount: 2,
    documents: [
      { id: 'document-001', index: 1, state: 'reviewed', filename: 'private-name.pdf' },
      { id: 'document-002', index: 2, state: 'unreviewed', path: '/private/taxes.pdf' }
    ],
    activeDocumentID: 'document-002',
    activeDocumentIndex: 2,
    maskSetVersion: 4,
    reviewedCount: 1,
    staleCount: 0,
    exportedCount: 0,
    currentReviewed: false,
    currentScanned: false,
    matchCount: null,
    selectedMatchCount: null,
    busy: false,
    userActionRequired: 'scan_and_review_current_document',
    folderPath: '/private',
    maskValues: ['SYNTHETIC SECRET']
  };
}

test('MCP status strips paths, filenames, mask values, and unknown fields', () => {
  const status = safeStatus(rawStatus());
  const text = JSON.stringify(status);
  assert.equal(status.document_count, 2);
  assert.equal(status.active_document_id, 'document-002');
  assert.equal(text.includes('private-name'), false);
  assert.equal(text.includes('/private'), false);
  assert.equal(text.includes('SYNTHETIC SECRET'), false);
  assert.equal(Object.hasOwn(status, 'folderPath'), false);
  assert.deepEqual(status.documents[0], { id: 'document-001', index: 1, state: 'reviewed' });
});

test('MCP status rejects non-opaque document identifiers', () => {
  const raw = rawStatus();
  raw.documents[0].id = 'taxpayer-name.pdf';
  assert.throws(() => safeStatus(raw), /invalid document status metadata/);
});

test('MCP commands ignore unrelated status written while Masker launches', () => {
  const before = {
    revision: 10,
    session_id: 'session-a',
    active_document_id: 'document-001',
    exported_count: 0
  };
  const unrelated = {
    ...before,
    revision: 1,
    user_action_required: 'open_or_review_document'
  };
  assert.equal(commandIsReflected('new', unrelated, before), false);
  assert.equal(commandIsReflected('resume', unrelated, before), false);
  assert.equal(commandIsReflected('open', unrelated, before, 'document-002'), false);
  assert.equal(commandIsReflected('next', {
    ...unrelated,
    active_document_id: 'document-002',
    user_action_required: 'scan_and_review_current_document'
  }, before), true);
});
