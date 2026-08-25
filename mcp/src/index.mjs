import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { McpServer } from '@modelcontextprotocol/server';
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import * as z from 'zod/v4';

const execFileAsync = promisify(execFile);
const documentIDSchema = z.string().regex(/^document-[0-9]{3,}$/);
const statusPath = process.env.MASKER_PRIVATE_BATCH_DIRECTORY
  ? resolve(process.env.MASKER_PRIVATE_BATCH_DIRECTORY, 'mcp-status.json')
  : join(homedir(), 'Library', 'Application Support', 'Masker', 'Private Batch', 'mcp-status.json');

const delay = milliseconds => new Promise(resolveDelay => setTimeout(resolveDelay, milliseconds));

function safeStatus(raw) {
  if (!raw || raw.format !== 'masker-mcp-status' || raw.version !== 1) {
    throw new Error('Masker has not published a valid private-batch status.');
  }
  const allowedStates = new Set(['idle', 'ready', 'busy']);
  const allowedPhases = new Set(['discovery', 'final_review']);
  const allowedDocumentStates = new Set(['unreviewed', 'reviewed', 'stale', 'exported']);
  const documents = Array.isArray(raw.documents) ? raw.documents.map(document => {
    if (!documentIDSchema.safeParse(document.id).success ||
        !Number.isInteger(document.index) ||
        !allowedDocumentStates.has(document.state)) {
      throw new Error('Masker published invalid document status metadata.');
    }
    return { id: document.id, index: document.index, state: document.state };
  }) : [];
  return {
    revision: Number.isInteger(raw.revision) ? raw.revision : 0,
    state: allowedStates.has(raw.state) ? raw.state : 'idle',
    session_id: typeof raw.sessionID === 'string' ? raw.sessionID : null,
    phase: allowedPhases.has(raw.phase) ? raw.phase : null,
    document_count: Number.isInteger(raw.documentCount) ? raw.documentCount : 0,
    documents,
    active_document_id: documentIDSchema.safeParse(raw.activeDocumentID).success
      ? raw.activeDocumentID
      : null,
    active_document_index: Number.isInteger(raw.activeDocumentIndex) ? raw.activeDocumentIndex : null,
    mask_set_version: Number.isInteger(raw.maskSetVersion) ? raw.maskSetVersion : null,
    reviewed_count: Number.isInteger(raw.reviewedCount) ? raw.reviewedCount : 0,
    stale_count: Number.isInteger(raw.staleCount) ? raw.staleCount : 0,
    exported_count: Number.isInteger(raw.exportedCount) ? raw.exportedCount : 0,
    current_reviewed: raw.currentReviewed === true,
    current_scanned: raw.currentScanned === true,
    match_count: Number.isInteger(raw.matchCount) ? raw.matchCount : null,
    selected_match_count: Number.isInteger(raw.selectedMatchCount) ? raw.selectedMatchCount : null,
    busy: raw.busy === true,
    user_action_required: typeof raw.userActionRequired === 'string'
      ? raw.userActionRequired.replace(/[^a-z0-9_]/g, '').slice(0, 80)
      : null
  };
}

async function readSafeStatus() {
  try {
    const raw = JSON.parse(await readFile(statusPath, 'utf8'));
    return safeStatus(raw);
  } catch (error) {
    return {
      revision: 0,
      state: 'idle',
      session_id: null,
      phase: null,
      document_count: 0,
      documents: [],
      active_document_id: null,
      active_document_index: null,
      mask_set_version: null,
      reviewed_count: 0,
      stale_count: 0,
      exported_count: 0,
      current_reviewed: false,
      current_scanned: false,
      match_count: null,
      selected_match_count: null,
      busy: false,
      user_action_required: 'open_masker_or_create_private_batch'
    };
  }
}

function toolResult(status) {
  return {
    content: [{ type: 'text', text: JSON.stringify(status) }],
    structuredContent: status
  };
}

function commandIsReflected(command, status, before, documentID) {
  if (status.revision === before.revision) return false;
  if (status.user_action_required === 'resolve_error_in_masker') return true;
  switch (command) {
    case 'new':
      return status.user_action_required === 'choose_folder_in_masker' ||
        (status.session_id !== null && status.session_id !== before.session_id);
    case 'resume':
      return status.active_document_id !== null &&
        status.user_action_required !== 'open_or_review_document';
    case 'open':
      return status.active_document_id === documentID ||
        status.user_action_required === 'mark_current_document_reviewed';
    case 'scan':
      return status.busy || status.current_scanned;
    case 'review':
      return status.current_reviewed ||
        status.user_action_required === 'scan_and_review_current_document';
    case 'next':
    case 'previous':
      return status.active_document_id !== before.active_document_id ||
        status.user_action_required === 'mark_current_document_reviewed' ||
        status.user_action_required === 'begin_final_pass' ||
        status.user_action_required === 'export_or_finish_batch';
    case 'begin-final':
      return status.phase === 'final_review' ||
        status.user_action_required === 'finish_discovery_review';
    case 'export':
      return status.exported_count > before.exported_count ||
        status.user_action_required === 'begin_final_pass' ||
        status.user_action_required === 'scan_and_review_current_document';
    default:
      return true;
  }
}

async function activateMasker(command, documentID) {
  const before = await readSafeStatus();
  const url = new URL(`masker://private-batch/${command}`);
  if (documentID) url.searchParams.set('document', documentID);
  const app = process.env.MASKER_APP_PATH;
  const args = app ? ['-a', app, url.href] : ['-a', 'Masker', url.href];
  await execFileAsync('/usr/bin/open', args, { timeout: 10_000 });
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await delay(100);
    const status = await readSafeStatus();
    if (commandIsReflected(command, status, before, documentID)) return status;
  }
  return readSafeStatus();
}

function registerCommand(server, name, title, description, command, annotations) {
  server.registerTool(
    name,
    { title, description, annotations },
    async () => toolResult(await activateMasker(command))
  );
}

function buildServer() {
  const server = new McpServer({
    name: 'masker',
    version: '1.7.0',
    description: 'Coordinates Masker private PDF batches without returning PDF text, filenames, paths, mask values, labels, or screenshots.'
  });

  server.registerTool(
    'begin_private_batch',
    {
      title: 'Begin Private Batch',
      description: 'Open Masker and ask the user to choose a local PDF folder. Returns only opaque status. Never ask for the folder path or PDF contents.',
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
    },
    async () => toolResult(await activateMasker('new'))
  );

  server.registerTool(
    'get_private_batch_status',
    {
      title: 'Get Private Batch Status',
      description: 'Return only opaque document IDs, counts, and workflow state. It never returns filenames, paths, PDF text, mask values, or labels.',
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
    },
    async () => toolResult(await readSafeStatus())
  );

  server.registerTool(
    'open_batch_document',
    {
      title: 'Open Batch Document',
      description: 'Open an opaque private-batch document in Masker for the user to review locally.',
      inputSchema: z.object({ document_id: documentIDSchema }),
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
    },
    async ({ document_id }) => toolResult(await activateMasker('open', document_id))
  );

  registerCommand(
    server,
    'resume_private_batch',
    'Resume Private Batch',
    'Open Masker and resume the locally saved private batch without exposing its folder or filenames.',
    'resume',
    { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
  );
  registerCommand(
    server,
    'scan_current_document',
    'Scan Current Document',
    'Start Masker\'s local scan for the current document. Poll status until busy is false; the user reviews results in Masker.',
    'scan',
    { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
  );
  registerCommand(
    server,
    'mark_current_document_reviewed',
    'Mark Current Document Reviewed',
    'Commit the user\'s current local review against the active mask-set version.',
    'review',
    { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }
  );
  registerCommand(
    server,
    'open_next_document',
    'Open Next Document',
    'Advance to the next opaque document after the current document has been marked reviewed.',
    'next',
    { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
  );
  registerCommand(
    server,
    'open_previous_document',
    'Open Previous Document',
    'Return to the previous opaque document in the private batch.',
    'previous',
    { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
  );
  registerCommand(
    server,
    'begin_final_pass',
    'Begin Final Pass',
    'Start a final review pass using the completed shared mask set. Every document must be rescanned and reviewed before export.',
    'begin-final',
    { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
  );
  registerCommand(
    server,
    'export_current_document',
    'Export Current Document',
    'Create a new sanitized copy of the current document after final review. Source PDFs are never overwritten.',
    'export',
    { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false }
  );

  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  void serveStdio(buildServer, { legacy: 'serve' });
  console.error('Masker MCP server ready; PDF contents remain local to Masker.');
}

export { activateMasker, buildServer, commandIsReflected, readSafeStatus, safeStatus, statusPath };
