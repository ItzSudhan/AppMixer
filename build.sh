#!/bin/zsh
# AppMixer build script
#   ./build.sh               build build/AppMixer.app (universal: Apple Silicon + Intel)
#   ./build.sh install       build, copy to /Applications and launch
#   ./build.sh dmg           build and package build/AppMixer-<version>.dmg
#   ./build.sh screenshots   render README screenshots (demo data) into docs/screenshots
set -euo pipefail
cd "$(dirname "$0")"

APP=build/AppMixer.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
MIN_MACOS=15.0

build() {
  rm -rf "$APP" build/obj
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
  for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -swift-version 5 \
      -target "$arch-apple-macos$MIN_MACOS" \
      Sources/*.swift -o "build/obj/AppMixer-$arch"
  done
  lipo -create build/obj/AppMixer-arm64 build/obj/AppMixer-x86_64 -output "$APP/Contents/MacOS/AppMixer"
  cp Info.plist "$APP/Contents/Info.plist"
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  codesign --force --sign - "$APP"
  echo "Built $PWD/$APP ($VERSION)"
}

case "${1:-}" in
  install)
    build
    pkill -x AppMixer 2>/dev/null || true
    rm -rf /Applications/AppMixer.app
    cp -R "$APP" /Applications/
    open /Applications/AppMixer.app
    echo "Installed to /Applications/AppMixer.app"
    ;;
  dmg)
    build
    DMG="build/AppMixer-$VERSION.dmg"
    STAGE=build/dmg
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "AppMixer" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "Created $PWD/$DMG"
    ;;
  screenshots)
    build
    rm -rf docs/screenshots
    # Launched through LaunchServices so the window renders like a normal app window.
    open -n -W "$APP" --args --screenshots "$PWD/docs/screenshots"
    ls docs/screenshots
    ;;
  "")
    build
    ;;
  *)
    echo "Usage: ./build.sh [install|dmg|screenshots]" >&2
    exit 1
    ;;
esac
