# Masker MCP

Masker MCP lets an agent coordinate Discovery Mode and Batch Convert while all PDF processing remains inside the native app.

The server exposes only opaque document IDs, counts, and workflow state. It has no tool for returning PDF text, filenames, paths, mask values, labels, or screenshots. Folder and mask-set selection happen in Masker.

## Requirements

- Masker 1.8.0 or later installed in Applications
- Node.js 20 or later
- Codex or another MCP host

## Install

```sh
./install.sh --configure-codex
```

Restart Codex after installation. The server supports the MCP 2026-07-28 stateless protocol and legacy 2025-era clients over stdio.

## Discovery Mode

1. Ask the agent to begin discovery.
2. Choose a folder in Masker. Masker finds PDFs recursively; the folder and filenames are not returned to the agent.
3. Review the current PDF locally and add mask values or labels.
4. Move freely through the opaque document IDs. There is no scan or review gate.
5. Export the finished mask set from section 2 in Masker.

## Batch Convert

1. Ask the agent to begin Batch Convert, or click **Batch Convert...** in Masker.
2. Choose one or more PDF folders and a mask-set JSON in Masker.
3. Masker processes every PDF recursively, skips existing `Masked PDFs` folders, and mirrors the selected hierarchies under one shared `Masked PDFs` folder.
4. Source PDFs are never combined or overwritten.
5. If Masker is already scanning or converting, the MCP receives `masker_busy_try_again_later`; the active work is never interrupted.

Discovery session data is stored locally with owner-only file permissions. MCP status is written separately and contains no document content or identifying strings.
