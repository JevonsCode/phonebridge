#!/bin/bash
# Build a self-contained preview. macOS ships Bash 3.2; avoid newer shell features.
set -euo pipefail
umask 022

project="$(cd "$(dirname "$0")/.." && pwd -P)"
version="0.6.1"
arch="$(uname -m)"
[ "$arch" != "x86_64" ] || arch="x64"
output="$project/artifacts/macos"
node_version="22.23.3"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--arch|--output)
      [ "$#" -ge 2 ] || { printf 'Missing value for %s\n' "$1" >&2; exit 1; }
      case "$1" in --version) version="$2";; --arch) arch="$2";; --output) output="$2";; esac
      shift 2;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1;;
  esac
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || { echo 'Invalid package version.' >&2; exit 1; }
case "$arch" in arm64) swift_arch=arm64; expected_host=arm64;; x64) swift_arch=x86_64; expected_host=x86_64;; *) echo 'Architecture must be arm64 or x64.' >&2; exit 1;; esac
[ "$(uname -s)" = Darwin ] || { echo 'Packaging requires macOS.' >&2; exit 1; }
[ "$(uname -m)" = "$expected_host" ] || { echo 'Build each architecture on its matching native runner.' >&2; exit 1; }
mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
base="phonebridge-$version-macos-$arch"
for extension in dmg zip dmg.sha256 zip.sha256; do
  [ ! -e "$output/$base.$extension" ] || { echo 'Output exists; choose a new output directory.' >&2; exit 1; }
done
work="$(mktemp -d "$output/.phonebridge-stage.XXXXXX")"
cleanup() {
  # Only remove the exact temporary directory created above, within the chosen output.
  case "$work" in "$output"/.phonebridge-stage.*) [ "$work" != "$output" ] && rm -rf -- "$work";; esac
}
trap cleanup EXIT
cache="$output/node-cache"
mkdir -p "$cache"
archive="node-v$node_version-darwin-$arch.tar.gz"
source="https://nodejs.org/dist/v$node_version"
curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 "$source/SHASUMS256.txt" -o "$work/SHASUMS256.txt"
expected="$(awk -v name="$archive" '$2 == name { print $1 }' "$work/SHASUMS256.txt")"
[[ "$expected" =~ ^[a-f0-9]{64}$ ]] || { echo 'Pinned Node archive missing or duplicated in official SHA256 file.' >&2; exit 1; }
if [ ! -f "$cache/$archive" ]; then
  curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 "$source/$archive" -o "$work/$archive"
  actual="$(shasum -a 256 "$work/$archive" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || { echo 'Official Node archive hash mismatch.' >&2; exit 1; }
  mv "$work/$archive" "$cache/$archive"
fi
actual="$(shasum -a 256 "$cache/$archive" | awk '{print $1}')"
[ "$actual" = "$expected" ] || { echo 'Cached Node archive hash mismatch.' >&2; exit 1; }
tar -xzf "$cache/$archive" -C "$work"
node_root="$work/node-v$node_version-darwin-$arch"
node="$node_root/bin/node"
npm="$node_root/lib/node_modules/npm/bin/npm-cli.js"
export PATH="$node_root/bin:$PATH"
"$node" -e 'if(process.platform!=="darwin"||process.arch!==process.argv[1]||process.version!=="v22.23.3")throw new Error("Runtime architecture/version mismatch")' "$arch"

# Compile from checked-in source; copy only build output and locked production dependencies.
(cd "$project/bridge" && "$node" "$npm" ci --ignore-scripts && "$node" "$npm" run build)
(cd "$project/desktop_app" && flutter build macos --release --build-name "$version")
mkdir -p "$work/image"
cp -R "$project/desktop_app/build/macos/Build/Products/Release/PhoneBridge.app" "$work/image/PhoneBridge.app"
app="$work/image/PhoneBridge.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources/runtime" "$resources/bridge" "$resources/desktop/macos" "$resources/desktop/test"
cp "$node" "$resources/runtime/node"
cp "$node_root/LICENSE" "$resources/runtime/LICENSE"
cp -R "$project/bridge/dist" "$resources/bridge/dist"
cp "$project/bridge/package.json" "$project/bridge/package-lock.json" "$resources/bridge/"
(cd "$resources/bridge" && "$node" "$npm" ci --omit=dev --ignore-scripts)
for name in server.mjs network.mjs network-transaction.mjs dashboard.html dashboard.js mcp-bootstrap.mjs; do
  cp "$project/desktop/$name" "$resources/desktop/$name"
done
for name in server.mjs service.mjs lifecycle.mjs phonebridge-mcp.sh mcp-launcher.mjs; do
  cp "$project/desktop/macos/$name" "$resources/desktop/macos/$name"
done
# The isolated suite is part of the headless support command, not a development runtime.
cp "$project/desktop/test/macos.test.mjs" "$resources/desktop/test/macos.test.mjs"
cp "$project/LICENSE" "$resources/LICENSE"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile PhoneBridge.icns" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
iconutil -c icns "$project/assets/brand/PhoneBridge.iconset" -o "$resources/PhoneBridge.icns"
"$node" - "$resources/package-manifest.json" "$version" "$arch" "$expected" "$source/$archive" <<'NODE'
const fs = require('node:fs');
const [, , path, version, arch, hash, source] = process.argv;
fs.writeFileSync(path, JSON.stringify({product:'PhoneBridge',version,platform:`darwin-${arch}`,minimumMacOS:'13.0',nodeVersion:'22.23.3',nodeArchiveSHA256:hash,nodeSource:source,signing:'ad-hoc',notarized:false},null,2)+'\n');
NODE
chmod 755 "$resources/runtime/node" "$app/Contents/MacOS/PhoneBridge"
codesign --force --sign - "$resources/runtime/node"
codesign --force --deep --sign - "$app"
codesign --verify --strict --verbose=2 "$app"
codesign --verify --strict "$resources/runtime/node"
file "$app/Contents/MacOS/PhoneBridge" "$resources/runtime/node"

# Headless commands exercise the actual signed, bundled native executable.
"$app/Contents/MacOS/PhoneBridge" --self-test
"$app/Contents/MacOS/PhoneBridge" --diagnose --report-path "$work/diagnostics.json"
"$node" - "$work/diagnostics.json" <<'NODE'
const report=JSON.parse(require('node:fs').readFileSync(process.argv[2],'utf8'));
if(report.product!=='PhoneBridge'||report.dryRun!==true)throw new Error('Invalid bundled diagnostic report');
NODE

ln -s /Applications "$work/image/Applications"
cat > "$work/image/READ-ME.txt" <<'TXT'
PhoneBridge preview for macOS 13 or later

Copy PhoneBridge.app to Applications (or your user's Applications folder) before opening.
This preview uses an ad-hoc signature and is not Developer ID signed or notarized.
Use Apple's normal approval flow if macOS asks you to approve the preview.
No quarantine attribute or Gatekeeper setting is changed by this package.
Scan the QR code with the PhoneBridge Android app on the same private network.
Closing the window leaves your owned login service running.
License and runtime provenance are inside PhoneBridge.app/Contents/Resources.
TXT
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$base.zip"
hdiutil create -volname "PhoneBridge $version" -srcfolder "$work/image" -format UDZO "$output/$base.dmg"
for extension in dmg zip; do
  (cd "$output" && shasum -a 256 "$base.$extension" > "$base.$extension.sha256")
done
printf '%s\n' "$output/$base.dmg" "$output/$base.zip"
