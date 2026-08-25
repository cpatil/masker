#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
module_cache="$project_dir/.build/module-cache"
test_root="$project_dir/tmp/pdfs/self-test"

mkdir -p "$module_cache" "$test_root"
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
  "$project_dir/Tests/MaskerSelfTest.swift" \
  -o "$project_dir/.build/masker-self-test"

"$project_dir/.build/masker-self-test" "$test_root"

swiftc \
  -swift-version 5 \
  -O \
  "$project_dir/Sources/Workflows.swift" \
  "$project_dir/Tests/WorkflowSelfTest.swift" \
  -o "$project_dir/.build/workflow-self-test"

"$project_dir/.build/workflow-self-test"

swiftc \
  -D SNAPSHOT_TEST \
  -swift-version 5 \
  -O \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreText \
  -framework PDFKit \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  -framework Vision \
  "$project_dir/Sources/Workflows.swift" \
  "$project_dir/Sources/MaskerCore.swift" \
  "$project_dir/Sources/MaskerApp.swift" \
  "$project_dir/Tests/MaskerUISnapshot.swift" \
  -o "$project_dir/.build/masker-ui-snapshot"

env MASKER_SNAPSHOT_VERSION="v1.8.1" \
  "$project_dir/.build/masker-ui-snapshot" \
  "$test_root/sample-tax-document.pdf" \
  "$test_root/ui-snapshot.png"
