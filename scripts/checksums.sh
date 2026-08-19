#!/bin/sh
# Write SHA256SUMS next to the release binaries.
#
# Run by `zig build release` rather than by hand: a checksum file that does not
# match the artifacts is worse than no checksum file, because the installer
# would then reject a good download.
set -eu

dir="${1:-zig-out/release}"
[ -d "$dir" ] || { echo "no such directory: $dir" >&2; exit 1; }

cd "$dir"

# Only the binaries, and never a previous SHA256SUMS.
set -- 
for f in quackling-*; do
    [ -f "$f" ] || continue
    case "$f" in SHA256SUMS) continue ;; esac
    set -- "$@" "$f"
done
[ $# -gt 0 ] || { echo "no release binaries found in $dir" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" > SHA256SUMS
elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@" > SHA256SUMS
else
    echo "need sha256sum or shasum" >&2
    exit 1
fi

echo "wrote $dir/SHA256SUMS ($# files)"
