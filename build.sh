#!/bin/zsh
# Builds "NUEM.app" into ./build — no Xcode project, only the Command Line Tools.
#
#   ./build.sh            build
#   ./build.sh run        build, then launch from ./build
#   ./build.sh install    build, copy to /Applications, then launch
#
# Environment:
#   ARCHS="arm64"                 architectures to build (default "arm64 x86_64" = universal binary)
#   CODESIGN_IDENTITY="My Cert"   signing identity (default "-" = ad hoc). A stable identity keeps the
#                                 Screen Recording permission across rebuilds.
set -euo pipefail
cd "${0:A:h}"

NAME="NUEM"
EXEC="NUEM"
BUNDLE_ID="io.github.tgtools123.nuem"
MIN_MACOS="14.0"
APP="build/$NAME.app"
archs=(${=ARCHS:-arm64 x86_64})
frameworks=(Cocoa SwiftUI Vision IOKit Metal MetalKit QuartzCore CoreImage ScreenCaptureKit ServiceManagement AVFoundation UniformTypeIdentifiers)

if ! command -v swiftc >/dev/null; then
  echo "swiftc not found. Install the Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

link_flags=()
for f in $frameworks; do link_flags+=(-framework "$f"); done

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
for arch in $archs; do
  echo "Compiling ($arch)…"
  swiftc -O -target "$arch-apple-macos$MIN_MACOS" $link_flags Sources/*.swift -o "build/obj/$EXEC-$arch"
done
lipo -create -output "$APP/Contents/MacOS/$EXEC" build/obj/$EXEC-*
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/. "$APP/Contents/Resources/"
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/$EXEC"))"

quit_running() {
  osascript -e "if application id \"$BUNDLE_ID\" is running then tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 0.5
}

case "${1:-}" in
  run)
    quit_running
    open "$APP"
    ;;
  install)
    quit_running
    rm -rf "/Applications/$NAME.app"
    ditto "$APP" "/Applications/$NAME.app"
    echo "Installed to /Applications/$NAME.app"
    open "/Applications/$NAME.app"
    ;;
  "") ;;
  *)
    echo "Unknown option: $1 (use: run, install)" >&2
    exit 1
    ;;
esac
