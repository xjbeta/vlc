#!/bin/sh
#
# Assemble libvlc.xcframework from a *static* VLC SDK.
#
# A static SDK (build.sh without --enable-shared) ships every plugin inside
# lib/libvlc-full-static.a instead of as one dylib per plugin. This script links
# that archive into a single framework binary and wraps it in an xcframework, so
# the app maps one file at startup and needs no plugin directory at all.
#
# The framework exposes VLC's low-level C API directly (Headers/vlc/*.h plus a
# modulemap), so `import libvlc` and `#include <vlc/vlc.h>` keep working; it is
# not a VLCKit-style Objective-C wrapper.
#
# Usage: eriri/make-vlc-framework.sh <sdk-dir>
#
# Notes on the link:
#   -force_load libvlc.a    the public API is only reachable by name from the
#                           app, so the linker would otherwise drop it and the
#                           framework would export a couple dozen symbols.
#   -u _vlc_static_modules  the module table lives in libvlc-full-static.a and
#                           nothing else references it (libvlccore imports it
#                           weakly), so force one reference to pull the whole
#                           plugin set in.
#   The rest of the archive is linked normally: it carries several copies of the
#   same contrib objects (one per plugin that uses them), and letting the linker
#   resolve by reference picks one copy each. -force_load on the whole archive
#   fails with duplicate symbols (the same reason harflabs/SwiftVLC ships a
#   fix-duplicate-symbols.sh).
#   -mmacosx-version-min    the deployment target is read back out of libvlc.a.
#                           Without it clang uses the host SDK's default and the
#                           framework ends up requiring the build machine's OS.
#
# Deliberately NOT used: -Wl,-no_compact_unwind. On arm64 that drops the compact
# unwind table, and then any C++ exception thrown in a plugin fails to unwind
# into its handler ("failed_throw" -> std::terminate). The static archive links
# fine with the compact unwind table intact. (SwiftVLC's fix-duplicate-symbols.sh
# documents the same hazard for nmedit: editing symbol tables can disturb
# __eh_frame / __gcc_except_tab / __compact_unwind and break C++ catch frames.)
#
set -euo pipefail

SDK="${1:?usage: make-vlc-framework.sh <sdk-dir>}"
API_ARCHIVE="$SDK/lib/libvlc.a"
HEADERS="$SDK/include/vlc"
DEST="$SDK/lib"

# build.sh leaves the merged archive in its own static-lib/ directory next to the
# install dir, not inside it. Accept it in either place so the script works
# whether or not something has already moved it.
ARCHIVE=""
for candidate in "$SDK/lib/libvlc-full-static.a" \
                 "$(dirname "$SDK")/static-lib/libvlc-full-static.a"; do
    if [ -f "$candidate" ]; then ARCHIVE="$candidate"; break; fi
done
if [ -z "$ARCHIVE" ]; then
    echo "make-vlc-framework: cannot find libvlc-full-static.a" >&2
    echo "  looked in $SDK/lib and $(dirname "$SDK")/static-lib" >&2
    ls -la "$SDK/lib" >&2 || true
    ls -la "$(dirname "$SDK")/static-lib" >&2 || true
    exit 1
fi

[ -f "$API_ARCHIVE" ] || { echo "make-vlc-framework: missing $API_ARCHIVE" >&2; exit 1; }
[ -d "$HEADERS" ] || { echo "make-vlc-framework: missing $HEADERS" >&2; exit 1; }
echo "make-vlc-framework: archive $ARCHIVE"

# Deployment target: take it from the objects VLC just built rather than
# hardcoding it, so the framework keeps matching the rest of the SDK.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && ar -x "$API_ARCHIVE" >/dev/null 2>&1 || true )
SAMPLE="$(ls "$WORK"/*.o 2>/dev/null | head -1 || true)"
DEPLOYMENT_TARGET="12.0"
if [ -n "$SAMPLE" ]; then
    DETECTED="$(vtool -show-build "$SAMPLE" 2>/dev/null | awk '/minos/ { print $2; exit }')"
    [ -n "$DETECTED" ] && DEPLOYMENT_TARGET="$DETECTED"
fi
echo "make-vlc-framework: deployment target $DEPLOYMENT_TARGET"

# System frameworks the archive's code references. Taken from a working link of
# this archive; VLCKit's own project lists the same set.
FRAMEWORKS="
AppKit
ApplicationServices
AudioToolbox
AudioUnit
AVFoundation
AVKit
Cocoa
CoreAudio
CoreFoundation
CoreGraphics
CoreImage
CoreMedia
CoreServices
CoreText
CoreVideo
DiskArbitration
Foundation
IOKit
IOSurface
Metal
OpenGL
QuartzCore
Security
SystemConfiguration
VideoToolbox
"

FRAMEWORK_ARGS=""
for f in $FRAMEWORKS; do
    FRAMEWORK_ARGS="$FRAMEWORK_ARGS -framework $f"
done

# 1. The framework slice.
SLICE="$WORK/libvlc.framework"
BIN="$SLICE/Versions/A/libvlc"
mkdir -p "$SLICE/Versions/A/Headers" "$SLICE/Versions/A/Modules" "$SLICE/Versions/A/Resources"

echo "make-vlc-framework: linking $BIN"
# shellcheck disable=SC2086
clang++ -dynamiclib -o "$BIN" \
    -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -Wl,-force_load,"$API_ARCHIVE" \
    -Wl,-u,_vlc_static_modules \
    -Wl,-install_name,@rpath/libvlc.framework/Versions/A/libvlc \
    -Wl,-current_version,1.0.0 \
    -Wl,-compatibility_version,1.0.0 \
    $FRAMEWORK_ARGS \
    -lz -lbz2 -liconv -lresolv \
    "$ARCHIVE"

cp -R "$HEADERS" "$SLICE/Versions/A/Headers/vlc"

cat > "$SLICE/Versions/A/Modules/module.modulemap" <<'EOF'
// VLC's low-level C API, exposed to Swift as `import libvlc`.
framework module libvlc {
    umbrella header "vlc/vlc.h"
    export *
    module * { export * }
}
EOF

cat > "$SLICE/Versions/A/Resources/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>libvlc</string>
	<key>CFBundleIdentifier</key><string>org.videolan.libvlc</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>libvlc</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
	<key>MinimumOSVersion</key><string>__DEPLOYMENT_TARGET__</string>
</dict>
</plist>
EOF
sed -i '' "s/__DEPLOYMENT_TARGET__/$DEPLOYMENT_TARGET/" "$SLICE/Versions/A/Resources/Info.plist"

ln -sfn Versions/Current/Headers   "$SLICE/Headers"
ln -sfn Versions/Current/Modules   "$SLICE/Modules"
ln -sfn Versions/Current/Resources "$SLICE/Resources"
ln -sfn Versions/Current/libvlc    "$SLICE/libvlc"
ln -sfn A                          "$SLICE/Versions/Current"

# 2. Wrap it in an xcframework, the format Xcode and SwiftPM expect.
echo "make-vlc-framework: creating libvlc.xcframework"
rm -rf "$DEST/libvlc.xcframework"
xcodebuild -create-xcframework -framework "$SLICE" -output "$DEST/libvlc.xcframework" >/dev/null

# 3. Compatibility shims. The app links -lvlc and -lvlccore against <sdk>/lib and
#    records @rpath/libvlc.framework/Versions/A/libvlc, so leave that path
#    resolvable inside the SDK as well. A static VLC has no separate libvlccore,
#    so the second name is just a second door into the same file.
SLICE_DIR="$(cd "$DEST/libvlc.xcframework" && ls -d macos-* | head -1)"
ln -sfn "libvlc.xcframework/$SLICE_DIR/libvlc.framework" "$DEST/libvlc.framework"
ln -sfn "libvlc.xcframework/$SLICE_DIR/libvlc.framework/Versions/A/libvlc" "$DEST/libvlc.dylib"
ln -sfn "libvlc.xcframework/$SLICE_DIR/libvlc.framework/Versions/A/libvlc" "$DEST/libvlccore.dylib"

echo "make-vlc-framework: built $DEST/libvlc.xcframework ($SLICE_DIR, $(stat -f%z "$DEST/libvlc.xcframework/$SLICE_DIR/libvlc.framework/Versions/A/libvlc") bytes)"
