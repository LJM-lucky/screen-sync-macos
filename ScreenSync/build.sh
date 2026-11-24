#!/bin/zsh
set -eu
source_dir=${0:A:h}
repo_dir=${source_dir:h}/m1ddc
app="${1:?Pass the output .app path}"
mkdir -p "$app/Contents/"{MacOS,Helpers,Resources}
make -C "$repo_dir"
cp "$repo_dir/m1ddc" "$app/Contents/Helpers/m1ddc"
cp "$repo_dir/LICENSE" "$app/Contents/Resources/m1ddc-LICENSE.txt"
cp "$source_dir/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
xcrun swiftc -target arm64-apple-macos26.0 -O -swift-version 6 -parse-as-library \
  "$source_dir/"*.swift -o "$app/Contents/MacOS/ScreenSync"
codesign --force --sign - "$app/Contents/Helpers/m1ddc"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
