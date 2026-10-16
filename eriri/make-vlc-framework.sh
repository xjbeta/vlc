#!/bin/sh
#
# Assemble libvlc.framework from a *static* VLC SDK.
#
# A static SDK (build.sh without --enable-shared) ships every plugin inside
# lib/libvlc-full-static.a instead of as one dylib per plugin. This script links
# that archive into a single framework binary, so the app maps one file at
# startup and needs no plugin directory at all.
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
#   fails with duplicate symbols.
#
# Deliberately NOT used: -Wl,-no_compact_unwind. On arm64 that drops both
# __unwind_info and __eh_frame, and then any C++ exception thrown in a plugin
# fails to unwind into its handler ("failed_throw" -> std::terminate). The
# static archive links fine with the compact unwind table intact.
#
set -euo pipefail

SDK="${1:?usage: make-vlc-framework.sh <sdk-dir>}"
ARCHIVE="$SDK/lib/libvlc-full-static.a"
API_ARCHIVE="$SDK/lib/libvlc.a"
HEADERS="$SDK/include/vlc"

[ -f "$ARCHIVE" ] || { echo "make-vlc-framework: missing $ARCHIVE" >&2; exit 1; }
[ -f "$API_ARCHIVE" ] || { echo "make-vlc-framework: missing $API_ARCHIVE" >&2; exit 1; }
[ -d "$HEADERS" ] || { echo "make-vlc-framework: missing $HEADERS" >&2; exit 1; }

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

FW="$SDK/lib/libvlc.framework"
BIN="$FW/Versions/A/libvlc"

rm -rf "$FW"
mkdir -p "$FW/Versions/A/Headers" "$FW/Versions/A/Modules" "$FW/Versions/A/Resources"

echo "make-vlc-framework: linking $BIN"
# shellcheck disable=SC2086
clang++ -dynamiclib -o "$BIN" \
    -Wl,-force_load,"$API_ARCHIVE" \
    -Wl,-u,_vlc_static_modules \
    -Wl,-install_name,@rpath/libvlc.framework/Versions/A/libvlc \
    -Wl,-current_version,1.0.0 \
    -Wl,-compatibility_version,1.0.0 \
    $FRAMEWORK_ARGS \
    -lz -lbz2 -liconv -lresolv \
    "$ARCHIVE"

cp -R "$HEADERS" "$FW/Versions/A/Headers/vlc"

cat > "$FW/Versions/A/Modules/module.modulemap" <<'EOF'
// VLC's low-level C API, exposed to Swift as `import libvlc`.
framework module libvlc {
    umbrella header "vlc/vlc.h"
    export *
    module * { export * }
}
EOF

cat > "$FW/Versions/A/Resources/Info.plist" <<'EOF'
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
</dict>
</plist>
EOF

# Framework version symlinks.
ln -sfn Versions/Current/Headers   "$FW/Headers"
ln -sfn Versions/Current/Modules   "$FW/Modules"
ln -sfn Versions/Current/Resources "$FW/Resources"
ln -sfn Versions/Current/libvlc    "$FW/libvlc"
ln -sfn A                          "$FW/Versions/Current"

# Compatibility shims: the app links -lvlc and -lvlccore against <sdk>/lib, and
# both now resolve to the one framework binary (dyld loads it once). A static
# VLC has no separate libvlccore, so the second name is just a second door into
# the same file.
ln -sfn libvlc.framework/Versions/A/libvlc "$SDK/lib/libvlc.dylib"
ln -sfn libvlc.framework/Versions/A/libvlc "$SDK/lib/libvlccore.dylib"

echo "make-vlc-framework: built $FW ($(stat -f%z "$BIN") bytes)"
