#!/bin/zsh
set -euo pipefail

source_dir="${0:A:h}"
install_root="${MASKER_MCP_INSTALL_DIR:-$HOME/Library/Application Support/Masker/MCP Server}"
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
print "Add it to Codex with:"
print "  codex mcp add masker -- '$install_root/run.sh'"

if [[ "${1:-}" == "--configure-codex" ]]; then
  codex mcp add masker -- "$install_root/run.sh"
  print "Configured Masker MCP in Codex. Restart Codex before using it."
fi
