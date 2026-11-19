#!/bin/zsh
# Build Courier.app on a Mac.
#   scripts/build.sh            build into build/Courier.app
#   scripts/build.sh --install  also replace ~/Applications/Courier.app and open it
# Signing: ad-hoc unless SIGN_IDENTITY is set (a codesigning identity; optionally SIGN_KEYCHAIN and
# SIGN_KEYCHAIN_PASSWORD_FILE). macOS keys the Accessibility permission to the signature, and an
# ad-hoc one changes with every build, so a fixed identity keeps the permission across builds.
set -eo pipefail
cd "$(dirname "$0")/.."
VERSION=$(git describe --always --dirty 2>/dev/null || date +%Y%m%d%H%M)
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
APP=build/Courier.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN/Courier $APP/Contents/MacOS/
sed "s/VERSION/$VERSION/" Resources/Info.plist > $APP/Contents/Info.plist
cp Resources/AppIcon.icns $APP/Contents/Resources/
if [[ -n "$SIGN_IDENTITY" ]]; then
  KC=()
  if [[ -n "$SIGN_KEYCHAIN" ]]; then
    [[ -n "$SIGN_KEYCHAIN_PASSWORD_FILE" ]] && security unlock-keychain -p "$(cat $SIGN_KEYCHAIN_PASSWORD_FILE)" $SIGN_KEYCHAIN
    KC=(--keychain "$SIGN_KEYCHAIN")
  fi
  codesign --force --sign "$SIGN_IDENTITY" $KC --timestamp=none $APP
else
  codesign --force --sign - $APP
fi
echo "built $APP ($VERSION)"
[[ "$1" == --install ]] || exit 0
DEST=~/Applications/Courier.app
if pgrep -x Courier >/dev/null; then
  osascript -e 'tell application id "io.github.liangjh0712.courier" to quit' >/dev/null 2>&1 || true
  for i in {1..20}; do pgrep -x Courier >/dev/null || break; sleep 0.25; done
  pkill -KILL -x Courier 2>/dev/null && sleep 1 || true
fi
mkdir -p ~/Applications
rm -rf $DEST
cp -R $APP $DEST
open $DEST
echo "installed $DEST"
