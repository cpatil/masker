#!/bin/zsh
set -euo pipefail

server_dir="${0:A:h}"
node_path="${MASKER_NODE_PATH:-$(command -v node || true)}"
if [[ -z "$node_path" ]]; then
  print -u2 "Masker MCP requires Node.js 20 or later."
  exit 1
fi

exec "$node_path" "$server_dir/src/index.mjs"
