#!/bin/zsh
set -euo pipefail

source_dir="${0:A:h}"
install_root="${MASKER_MCP_INSTALL_DIR:-$HOME/Library/Application Support/Masker/MCP Server}"

agent_setup() {
  print "Masker MCP setup"
  print ""
  print "Privacy boundary:"
  print "  - PDF processing and file selection stay inside the Masker app."
  print "  - MCP receives only opaque document IDs, counts, and workflow state."
  print "  - MCP cannot read filenames, paths, PDF text, mask values, labels, searches, or screenshots."
  print "  - A busy Masker returns masker_busy_try_again_later and is never interrupted."
  print ""
  print "Requirements:"
  print "  - Masker installed in /Applications"
  print "  - Node.js 20 or later, including npm"
  print "  - Codex, Claude Code, or another stdio MCP host"
  print ""
  print "Install and configure:"
  print "  Codex:      ./masker mcp install codex"
  print "  Claude Code: ./masker mcp install claude"
  print "  Both:       ./masker mcp install both"
  print ""
  print "Verify after restarting the host:"
  print "  codex mcp list"
  print "  claude mcp list"
  print ""
  print "The server supports Discovery Mode and Batch Convert. Folder and mask-set choices remain user-controlled in Masker."
  print "This output is bundled with the local checkout; it does not fetch remote instructions."
}

usage() {
  print "Usage: ./install.sh [--configure-codex|--configure-claude|--configure-both]"
  print "       ./install.sh --agent-setup"
}

mode="${1:-}"
case "$mode" in
  --agent-setup)
    agent_setup
    exit 0
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  ""|--configure-codex|--configure-claude|--configure-both)
    ;;
  *)
    print -u2 "Unknown option: $mode"
    usage >&2
    exit 2
    ;;
esac

node_path="${MASKER_NODE_PATH:-$(command -v node || true)}"
npm_path="$(command -v npm || true)"

if [[ -z "$node_path" || -z "$npm_path" ]]; then
  print -u2 "Masker MCP requires Node.js 20 or later, including npm."
  exit 1
fi

node_major="$($node_path -p 'Number(process.versions.node.split(".")[0])')"
if (( node_major < 20 )); then
  print -u2 "Masker MCP requires Node.js 20 or later; found $($node_path --version)."
  exit 1
fi

mkdir -p "$install_root/src"
ditto "$source_dir/src/index.mjs" "$install_root/src/index.mjs"
ditto "$source_dir/package.json" "$install_root/package.json"
ditto "$source_dir/package-lock.json" "$install_root/package-lock.json"
ditto "$source_dir/run.sh" "$install_root/run.sh"
chmod 700 "$install_root/run.sh"

cd "$install_root"
"$npm_path" ci --omit=dev --ignore-scripts

print "Installed Masker MCP at: $install_root"
print "Configure Codex with:"
print "  codex mcp add masker -- '$install_root/run.sh'"
print "Configure Claude Code with:"
print "  claude mcp add --scope user masker -- '$install_root/run.sh'"
print "Run './masker mcp info' from the Masker checkout for the privacy boundary and setup summary."

if [[ "$mode" == "--configure-codex" || "$mode" == "--configure-both" ]]; then
  if ! command -v codex >/dev/null 2>&1; then
    print -u2 "Codex CLI was not found; Masker MCP was installed but not registered in Codex."
    exit 1
  fi
  codex mcp add masker -- "$install_root/run.sh"
  print "Configured Masker MCP in Codex. Restart Codex before using it."
fi

if [[ "$mode" == "--configure-claude" || "$mode" == "--configure-both" ]]; then
  if ! command -v claude >/dev/null 2>&1; then
    print -u2 "Claude Code CLI was not found; Masker MCP was installed but not registered in Claude Code."
    exit 1
  fi
  claude mcp add --scope user masker -- "$install_root/run.sh"
  print "Configured Masker MCP in Claude Code. Restart Claude Code before using it."
fi
