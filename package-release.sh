#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/Masker.app"
build_dir="$project_dir/.build/release"
module_cache="$project_dir/.build/module-cache-release"
version="$(plutil -extract CFBundleShortVersionString raw "$project_dir/Info.plist")"
zip_path="$build_dir/Masker-v${version}-macOS-universal.zip"

mkdir -p "$build_dir" "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFT_MODULECACHE_PATH="$module_cache"

compile_arch() {
  local architecture="$1"
  swiftc \
    -target "${architecture}-apple-macosx13.0" \
    -swift-version 5 \
    -O \
    -framework AppKit \
    -framework CoreGraphics \
    -framework CoreText \
    -framework PDFKit \
    -framework SwiftUI \
    -framework UniformTypeIdentifiers \
    -framework Vision \
    "$project_dir/Sources/MaskerCore.swift" \
    "$project_dir/Sources/MaskerApp.swift" \
    -o "$build_dir/Masker-$architecture"
}

compile_arch arm64
compile_arch x86_64

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
lipo -create "$build_dir/Masker-arm64" "$build_dir/Masker-x86_64" -output "$app_dir/Contents/MacOS/Masker"
codesign --force --deep --sign - "$app_dir"

ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$zip_path"
codesign --verify --deep --strict "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"
file "$app_dir/Contents/MacOS/Masker"
shasum -a 256 "$zip_path"
echo "Packaged $zip_path"
