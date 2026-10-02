#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/Masker.app"
contents_dir="$app_dir/Contents"
module_cache="$project_dir/.build/module-cache"

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$module_cache"
cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/presidio/presidio_helper.py" "$contents_dir/Resources/presidio_helper.py"
cp "$project_dir/presidio/install_presidio.sh" "$contents_dir/Resources/install_presidio.sh"

export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFT_MODULECACHE_PATH="$module_cache"

swiftc \
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
  "$project_dir/Sources/PresidioDiscovery.swift" \
  "$project_dir/Sources/MaskerApp.swift" \
  -o "$contents_dir/MacOS/Masker"

codesign --force --deep --sign - "$app_dir"
echo "Built $app_dir"
