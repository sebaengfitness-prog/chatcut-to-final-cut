#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
./scripts/build.sh
mkdir -p "$HOME/Applications"
APP="$HOME/Applications/ChatCut to Final Cut.app"
if [[ -e "$APP" ]]; then
  VERSIONED="$HOME/Applications/ChatCut to Final Cut - previous $(date +%Y%m%d-%H%M%S).app"
  mv "$APP" "$VERSIONED"
fi
ditto --noextattr --norsrc "build/ChatCut to Final Cut.app" "$APP"
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"
print "$APP"
