#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<USAGE
Usage:
  $0 <gcc|gdb> <version|stable|latest> <host_platform> <target_platform> <revision>

Examples:
  $0 gcc stable linux-x64 linux-x64 1
  $0 gcc stable linux-x64 windows-x64 1
  $0 gdb stable windows-x64 windows-x64 1
USAGE
}

if [ "$#" -ne 5 ]; then
    usage >&2
    exit 2
fi

TOOL="$1"
VERSION="$2"
HOST_PLATFORM="$3"
TARGET_PLATFORM="$4"
REVISION="$5"

case "$TOOL" in
    gcc)
        exec "$SCRIPT_DIR/build-gcc.sh" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION"
        ;;
    gdb)
        exec "$SCRIPT_DIR/build-gdb.sh" "$VERSION" "$HOST_PLATFORM" "$TARGET_PLATFORM" "$REVISION"
        ;;
    *)
        printf 'Unsupported GNU tool: %s\n' "$TOOL" >&2
        exit 2
        ;;
esac
