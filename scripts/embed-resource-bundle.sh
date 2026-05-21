#!/usr/bin/env bash
# Re-shape one SwiftPM resource bundle into a proper macOS bundle and
# drop it under an .app's Resources/ directory.
#
# SwiftPM emits resource bundles as a flat directory (`MyTarget.bundle/`
# containing the resources directly) with no Info.plist and no Contents/
# subtree. macOS's hardened runtime accepts launching an app with such a
# bundle on the developer's own Mac because the launch services cache
# already knows the binary, but on a fresh Mac the seal verification
# rejects the structure and the app dies immediately.
#
# This wrapper rebuilds the bundle as
#
#     MyTarget.bundle/
#         Contents/
#             Info.plist          (minimal — bundle id + name + version)
#             Resources/
#                 <original files>
#
# Bundle.module's lookup (`bundle.url(forResource:withExtension:)`)
# still finds the resources because that's the standard location.
#
# Usage:  embed-resource-bundle.sh <src-bundle-dir> <dest-resources-dir> <bundle-id-prefix>

set -euo pipefail

src="${1:?source bundle path required}"
dest_resources="${2:?destination Resources/ path required}"
id_prefix="${3:?bundle id prefix required}"

name="$(basename "$src")"
stem="${name%.bundle}"
dest="$dest_resources/$name"

rm -rf "$dest"
mkdir -p "$dest/Contents/Resources"

# Copy the original payload into Resources/. `-R` preserves nested
# directories so anything SwiftPM put alongside the top-level files
# comes along.
shopt -s dotglob nullglob
for entry in "$src"/*; do
    [ -e "$entry" ] || continue
    cp -R "$entry" "$dest/Contents/Resources/"
done
shopt -u dotglob nullglob

cat > "$dest/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyLists-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>${id_prefix}.${stem}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${stem}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF
