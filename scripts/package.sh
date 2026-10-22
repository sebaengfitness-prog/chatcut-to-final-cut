#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
case "${1:-}" in
  "") CHATCUT_ARCHS='arm64 x86_64' ./scripts/build.sh ;;
  --skip-build) ;;
  *) print -u2 "Usage: scripts/package.sh [--skip-build]"; exit 2 ;;
esac

task_source_app="$PWD/build/ChatCut to Final Cut.app"
task_binary="$task_source_app/Contents/MacOS/ChatCutToFinalCut"
task_plist="$task_source_app/Contents/Info.plist"
[[ -f "$task_binary" ]] || { print -u2 "Build the app before packaging."; exit 1; }
for task_arch in arm64 x86_64; do xcrun lipo "$task_binary" -verify_arch "$task_arch"; done
task_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_plist")
[[ "$task_version" == <->.<->.<-> ]] || { print -u2 "Unexpected app version: $task_version"; exit 1; }
task_source_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
[[ "$task_version" == "$task_source_version" ]] || { print -u2 'Built app version differs from Resources/Info.plist; rebuild before packaging.'; exit 1; }
task_stem="ChatCut-to-Final-Cut-$task_version-universal"
task_dist="$PWD/dist"
task_staging=$(mktemp -d "${TMPDIR:-/tmp/}chatcut-package.XXXXXX")
trap 'rm -rf "$task_staging"' EXIT
task_payload="$task_staging/payload"
mkdir -p "$task_payload" "$task_dist"

# The distribution is assembled from an explicit allowlist, never the checkout/build directory.
ditto --noextattr --norsrc "$task_source_app" "$task_payload/ChatCut to Final Cut.app"
ln -s /Applications "$task_payload/Applications"
# These reviewed public documents are the complete documentation allowlist. Private
# verification notes and project snapshots elsewhere in docs/build are never copied.
task_public_documents=(README.md CHANGELOG.md LICENSE docs/COMPATIBILITY.md docs/SNAPSHOT.md)
for task_document in "${task_public_documents[@]}"; do
  [[ -f "$task_document" ]] || { print -u2 "Missing public release document: $task_document"; exit 1; }
  mkdir -p "$task_payload/${task_document:h}"
  cp "$task_document" "$task_payload/$task_document"
done
cat > "$task_payload/Install.txt" <<'INSTALL'
ChatCut to Final Cut

Requires macOS 13 or later. Includes native Apple silicon and Intel executables.

Drag ChatCut to Final Cut.app onto Applications, then launch the app from Applications.
When using the ZIP, unzip it before moving the app to Applications.

This release is ad-hoc signed and has not been notarized. macOS may require explicit
approval before the first launch. No installation helper, background service or
account is required by this app.

Choose a ChatCut XML export, locate the original media folders and convert the
timeline. Final Cut Pro must be installed to import the resulting FCPXML.
INSTALL
xattr -cr "$task_payload"
# Verify the clean staged copy. A cloud-managed checkout may attach Finder metadata
# to build/ after creation; those extended attributes are intentionally excluded.
codesign --verify --deep --strict --all-architectures "$task_payload/ChatCut to Final Cut.app"

task_dmg="$task_staging/$task_stem.dmg"
task_zip="$task_staging/$task_stem.zip"
hdiutil create -quiet -format UDZO -fs HFS+ -volname 'ChatCut to Final Cut' -srcfolder "$task_payload" "$task_dmg"
hdiutil verify -quiet "$task_dmg"
# Suppress Finder/resource-fork metadata, while retaining the drag-to-Applications symlink.
COPYFILE_DISABLE=1 ditto --noextattr --norsrc -c -k "$task_payload" "$task_zip"
unzip -tq "$task_zip"
mv -f "$task_dmg" "$task_dist/$task_stem.dmg"
mv -f "$task_zip" "$task_dist/$task_stem.zip"
(
  cd "$task_dist"
  shasum -a 256 "$task_stem.dmg" "$task_stem.zip" > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
print "$task_dist/$task_stem.dmg"
print "$task_dist/$task_stem.zip"
print "$task_dist/SHA256SUMS.txt"
