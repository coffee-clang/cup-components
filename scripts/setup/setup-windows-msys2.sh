#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
environment="${1:-}"

case "$environment" in
    ucrt64)
        package_file="$SCRIPT_DIR/msys2-ucrt64-packages.txt"
        ;;
    clang64)
        package_file="$SCRIPT_DIR/msys2-clang64-packages.txt"
        ;;
    *)
        echo "usage: $0 <ucrt64|clang64>" >&2
        exit 2
        ;;
esac

if [ ! -f "$package_file" ]; then
    echo "MSYS2 package list not found: $package_file" >&2
    exit 1
fi

mapfile -t packages < <(grep -v '^[[:space:]]*$' "$package_file" | grep -v '^[[:space:]]*#')

if [ "${#packages[@]}" -eq 0 ]; then
    echo "MSYS2 package list is empty: $package_file" >&2
    exit 1
fi

pacman -S --needed --noconfirm "${packages[@]}"
