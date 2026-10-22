#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
task_destination="$PWD/build/ChatCut to Final Cut.app"
# Sign outside the source checkout so cloud/file-provider attributes cannot enter the bundle.
task_staging=$(mktemp -d "${TMPDIR:-/tmp/}chatcut-build.XXXXXX")
trap 'rm -rf "$task_staging"' EXIT
task_app="$task_staging/ChatCut to Final Cut.app"
task_sdk=$(xcrun --show-sdk-path)
task_archs=(arm64 x86_64)
# Optional local-development override. Release packaging always requires both slices.
if [[ -n "${CHATCUT_ARCHS:-}" ]]; then task_archs=(${=CHATCUT_ARCHS}); fi
task_archs=(${(u)task_archs})
task_slices=()
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
for task_arch in "${task_archs[@]}"; do
  case "$task_arch" in
    arm64|x86_64) ;;
    *) print -u2 "Unsupported architecture: $task_arch (choose arm64 or x86_64)."; exit 2 ;;
  esac
  task_slice="$task_staging/ChatCutToFinalCut-$task_arch"
  xcrun swiftc -O -swift-version 5 -sdk "$task_sdk" \
    -target "$task_arch-apple-macosx13.0" -module-name ChatCutToFinalCut \
    -file-prefix-map "$PWD"=. -debug-prefix-map "$PWD"=. \
    Sources/TimelineConverter.swift Sources/TitleRecovery.swift Sources/ExportService.swift Sources/main.swift \
    -o "$task_slice"
  task_slices+=("$task_slice")
done
xcrun lipo -create "${task_slices[@]}" -output "$task_app/Contents/MacOS/ChatCutToFinalCut"
cp Resources/Info.plist "$task_app/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$task_app/Contents/Resources/AppIcon.icns"; fi
xattr -cr "$task_app"
codesign --force --sign - --timestamp=none "$task_app"
codesign --verify --deep --strict --all-architectures "$task_app"
for task_arch in "${task_archs[@]}"; do
  xcrun lipo "$task_app/Contents/MacOS/ChatCutToFinalCut" -verify_arch "$task_arch"
done
mkdir -p "$PWD/build"
# Use a new bundle directory; ditto must not retain files left by a previous build.
if [[ -e "$task_destination" ]]; then rm -rf "$task_destination"; fi
ditto --noextattr --norsrc "$task_app" "$task_destination"
codesign --verify --deep --strict --all-architectures "$task_destination"
print "$task_destination"
