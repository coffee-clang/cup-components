#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/package/package-common.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CUP_REPRODUCIBLE_ARCHIVES=true
export SOURCE_DATE_EPOCH=946684800
HOST_PLATFORM=linux-x64

make_root() {
    local dir="$1"
    mkdir -p "$dir/pkg/bin" "$dir/pkg/share/data"
    printf '#!/bin/sh\necho ok\n' > "$dir/pkg/bin/tool"
    chmod 0755 "$dir/pkg/bin/tool"
    printf 'payload\n' > "$dir/pkg/share/data/value.txt"
    ln -s value.txt "$dir/pkg/share/data/current"
    touch -d '2025-01-01 12:00:00' "$dir/pkg/bin/tool"
    touch -d '2026-02-03 04:05:06' "$dir/pkg/share/data/value.txt"
    package_normalize_timestamps "$dir/pkg"
}

mkdir -p "$tmp/a/out" "$tmp/b/out"
make_root "$tmp/a"
sleep 1
make_root "$tmp/b"
for format in tar.xz tar.gz zip; do
    create_archive "$format" pkg "$tmp/a/pkg" "$tmp/a/out" linux-x64
    create_archive "$format" pkg "$tmp/b/pkg" "$tmp/b/out" linux-x64
    cmp "$tmp/a/out/pkg.$format" "$tmp/b/out/pkg.$format"
done

echo REPRODUCIBLE_ARCHIVES=PASS
