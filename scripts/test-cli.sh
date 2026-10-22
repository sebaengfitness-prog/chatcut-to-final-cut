#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_binary="${1:-$task_root/build/ChatCut to Final Cut.app/Contents/MacOS/ChatCutToFinalCut}"
task_scratch="$(mktemp -d /tmp/chatcut-cli-tests.XXXXXX)"
trap 'rm -rf "$task_scratch"' EXIT
cd "$task_root"

if [[ ! -x "$task_binary" ]]; then
  print -u2 "Build the app first with ./scripts/build.sh, or pass its executable path."
  exit 1
fi
"$task_binary" --help > "$task_scratch/help.txt"
grep -Fq -- '--convert' "$task_scratch/help.txt"

mkdir -p "$task_scratch/media/Media"
for task_filename in 'Camera A.mov' 'Camera B.mov' 'Sound.wav'; do
  printf '%s\n' 'Synthetic test placeholder; not playable media.' > "$task_scratch/media/Media/$task_filename"
done
"$task_binary" --convert "$task_root/Tests/Fixtures/linked-av.xml" \
  --media-root "$task_scratch/media" \
  --output-dir "$task_scratch/output" \
  --warnings "$task_root/Tests/Fixtures/linked-av.warnings.json" > "$task_scratch/result.json"
xcrun swift Tests/VerifyCLIResult.swift "$task_scratch/result.json"
