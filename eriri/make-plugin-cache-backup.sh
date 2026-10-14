#!/bin/sh
#
# Keep a backup of the plugin cache next to it, for a built SDK.
#
# libvlc keys plugins.dat on each plugin file's contents (E005), so any copy of
# the SDK keeps the cache valid whatever it does with timestamps. What can still
# go wrong is losing the file itself -- a partial copy, a clean-up -- and a
# missing cache costs a full scan of the plugin directory, one dlopen per
# plugin: 100 s and more on an external volume, where the kernel has to
# validate each freshly created dylib's code signature. vlc_cache_load() falls
# back on plugins.dat.bak, so shipping one turns that into a few reads.
#
# Usage: make-plugin-cache-backup.sh <SDK root>     e.g. vlc-macosx-arm64
# Writes: <SDK>/lib/vlc/plugins/plugins.dat.bak
#
set -eu

SDK=${1:?usage: $0 <SDK root>}
PLUGINS="$SDK/lib/vlc/plugins"
CACHE="$PLUGINS/plugins.dat"

[ -f "$CACHE" ] || {
    echo "no plugin cache: $CACHE" >&2
    echo "run vlc-cache-gen first, the backup has to match it" >&2
    exit 1
}

cp "$CACHE" "$PLUGINS/plugins.dat.bak"

echo "backup: $(du -h "$PLUGINS/plugins.dat.bak" | cut -f1)"
