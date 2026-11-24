#!/bin/zsh
# Build MorningstarAblesetBridge and install it to ~/Applications, then open it. Run from
# Terminal: apps can't run from inside Dropbox.
set -e
cd "$(dirname "$0")"
fail() {
  echo
  echo "Error $1: $2"
  echo "Look up this code on the MorningstarAblesetBridge error list:"
  echo "  https://github.com/jonpikereally/MorningstarAblesetBridge/blob/main/ERRORS.md"
  exit 1
}
./build.sh
APP="$HOME/Applications/MorningstarAblesetBridge.app"
pkill -x MorningstarAblesetBridge 2>/dev/null || true
sleep 0.5
mkdir -p ~/Applications || fail MAB-601 "Couldn't create ~/Applications."
rm -rf "$APP"
ditto --norsrc MorningstarAblesetBridge.app "$APP" || fail MAB-601 "Couldn't copy MorningstarAblesetBridge into ~/Applications."
xattr -cr "$APP"
codesign --force --sign - "$APP" || fail MAB-602 "Couldn't sign MorningstarAblesetBridge for this Mac."
open "$APP" || fail MAB-603 "MorningstarAblesetBridge was installed but couldn't be opened. Open it from ~/Applications yourself."
echo "Installed $APP — look for “MC4” in the menu bar."
