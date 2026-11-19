#!/bin/zsh
# Build InputBar.app.
#   scripts/build-app.sh                  build for this Mac, sign, install to ~/Applications and open
#   scripts/build-app.sh --package OUT    build an unsigned arm64 app and pack it to OUT (.tgz); works on Linux too,
#                                         install it on the Mac with scripts/install-app.sh OUT
# Signing: ad-hoc by default. macOS keys the Automation grant (InputBar → Ghostty) to the signature,
# and an ad-hoc one changes with every build, so set SIGN_IDENTITY (a codesigning identity name or
# hash, optionally SIGN_KEYCHAIN and SIGN_KEYCHAIN_PASSWORD_FILE) to keep the grant across builds.
set -euo pipefail

ROOT=${0:A:h:h}
VERSION=$(git -C $ROOT describe --always --dirty 2>/dev/null || date +%Y%m%d%H%M)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
B=$WORK/InputBar.app
mkdir -p $B/Contents/MacOS $B/Contents/Resources

if [[ ${1:-} == --package ]]; then
  OUT=${2:?--package needs an output path}
  (cd $ROOT/app && GOOS=darwin GOARCH=arm64 go build -trimpath -o $B/Contents/MacOS/InputBar .)
else
  (cd $ROOT/app && go build -trimpath -o $B/Contents/MacOS/InputBar .)
fi
cat > $B/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.inputbar</string>
  <key>CFBundleName</key><string>InputBar</string>
  <key>CFBundleExecutable</key><string>InputBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppleEventsUsageDescription</key><string>把输入框里写的内容送进 Ghostty 当前的终端。</string>
</dict>
</plist>
EOF
tar -C $WORK -czf $WORK/app.tgz InputBar.app
if [[ ${1:-} == --package ]]; then
  cp $WORK/app.tgz $OUT
  echo "packed $OUT ($VERSION)"
  exit 0
fi
exec zsh $ROOT/scripts/install-app.sh $WORK/app.tgz
