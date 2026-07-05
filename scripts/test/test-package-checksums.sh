#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
source "$ROOT/scripts/package/package-common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
base="fixture-1.0.0-linux-x64-linux-x64"
printf one > "$TMP/$base.tar.xz"
printf two > "$TMP/$base.tar.gz"
printf three > "$TMP/$base.zip"
generate_package_checksums "$base" "$TMP"
verify_package_checksums "$base" "$TMP"
printf tampered >> "$TMP/$base.zip"
if (verify_package_checksums "$base" "$TMP") >/dev/null 2>&1; then
    echo "checksum mismatch was not detected" >&2
    exit 1
fi
echo "package checksum tests passed"
