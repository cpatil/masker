# Masker MCP

Masker MCP lets an agent coordinate a private batch while the user reviews every PDF inside the native app.

The server exposes only opaque document IDs, counts, and workflow state. It has no tool for returning PDF text, filenames, paths, mask values, labels, or screenshots. Folder selection and document review happen in Masker.

## Requirements

- Masker 1.7.0 or later installed in Applications
- Node.js 20 or later
- Codex or another MCP host

## Install

```sh
./install.sh --configure-codex
```

Restart Codex after installation. The MCP server supports both the MCP 2026-07-28 stateless protocol and legacy 2025-era clients over stdio.

## Workflow

1. Ask the agent to begin a Masker private batch.
2. Choose the folder in Masker. The folder path is not returned to the agent.
3. Review the current document, add mask values and labels, then mark it reviewed.
4. Continue through every opaque document ID.
5. Begin the final pass. Every PDF is rescanned with the final shared mask set.
6. Review and export each sanitized copy. Source PDFs are never overwritten.

Private session data is stored locally with owner-only file permissions. MCP status is written separately and contains no document content or identifying strings.
