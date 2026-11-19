#!/bin/zsh
# On the Mac: sign a packed InputBar.app (from build-app.sh), replace ~/Applications/InputBar.app and open it.
#   scripts/install-app.sh APP.tgz
# Signing as in build-app.sh: SIGN_IDENTITY [SIGN_KEYCHAIN, SIGN_KEYCHAIN_PASSWORD_FILE], else ad-hoc.
set -euo pipefail

ARCHIVE=$1
APP=$HOME/Applications/InputBar.app
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
tar -C $WORK -xzf $ARCHIVE
B=$WORK/InputBar.app

SIGN=(--sign -)
if [[ -n ${SIGN_IDENTITY:-} ]]; then
  SIGN=(--sign "$SIGN_IDENTITY")
  if [[ -n ${SIGN_KEYCHAIN:-} ]]; then
    [[ -n ${SIGN_KEYCHAIN_PASSWORD_FILE:-} ]] && security unlock-keychain -p "$(cat $SIGN_KEYCHAIN_PASSWORD_FILE)" $SIGN_KEYCHAIN
    SIGN+=(--keychain "$SIGN_KEYCHAIN")
  fi
fi
codesign --force $SIGN --identifier local.inputbar --timestamp=none $B
codesign --verify --strict $B

# Quit the running one; kill it if it does not go.
if pgrep -f "$APP/Contents/MacOS/InputBar" >/dev/null; then
  osascript -e 'tell application id "local.inputbar" to quit' >/dev/null 2>&1 || true
  for i in {1..20}; do pgrep -f "$APP/Contents/MacOS/InputBar" >/dev/null || break; sleep 0.25; done
  pkill -KILL -f "$APP/Contents/MacOS/InputBar" 2>/dev/null && sleep 1 || true
fi
mkdir -p $HOME/Applications
rm -rf $APP.old
[[ -d $APP ]] && mv $APP $APP.old
mv $B $APP
rm -rf $APP.old
echo "installed $APP ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' $APP/Contents/Info.plist))"
open -a $APP
