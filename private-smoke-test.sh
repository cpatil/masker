#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/private/pdf/folder" >&2
  exit 2
fi

project_dir="${0:A:h}"
module_cache="$project_dir/.build/module-cache"

mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFT_MODULECACHE_PATH="$module_cache"

swiftc \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreText \
  -framework PDFKit \
  -framework Vision \
  "$project_dir/Sources/MaskerCore.swift" \
  "$project_dir/Tests/PrivateCorpusSmokeTest.swift" \
  -o "$project_dir/.build/private-corpus-smoke-test"

"$project_dir/.build/private-corpus-smoke-test" "$1"
