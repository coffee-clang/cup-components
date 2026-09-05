#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Usage:
  $0 <host_platform> <target_platform>
USAGE
}

if [ "$#" -ne 2 ]; then
    usage >&2
    exit 2
fi

HOST_PLATFORM="$1"
TARGET_PLATFORM="$2"
source dist/release.env

rm -rf dist/package-test
mkdir -p dist/package-test
tar -xJf "dist/$package_base.tar.xz" -C dist/package-test

root="dist/package-test/$package_base"
tmpdir="$(mktemp -d /tmp/cup-ld-test.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

info_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); found=1 } END { if (!found) exit 1 }' "$root/info.txt"
}

require_info() {
    local key="$1"
    local expected="$2"
    local actual

    actual="$(info_value "$key")" || {
        echo "missing GNU ld metadata field: $key" >&2
        exit 1
    }
    [ "$actual" = "$expected" ] || {
        echo "unexpected GNU ld metadata: $key=$actual; expected $expected" >&2
        exit 1
    }
}

require_info package.component linker
require_info package.tool ld
require_info platform.host "$HOST_PLATFORM"
require_info platform.target "$TARGET_PLATFORM"
require_info source.primary.name binutils
require_info config.plugins true
require_info config.nls false
require_info config.debuginfod false
require_info contents.binutils_toolbox false
require_info contents.gcc_lto_plugin false
require_info features.link true

if grep -q '^package.revision=' "$root/info.txt"; then
    echo "revisionless GNU ld package unexpectedly declares package.revision" >&2
    exit 1
fi

case "$TARGET_PLATFORM" in
    linux-x64|linux-arm64)
        require_info features.link_elf true
        require_info features.link_pe false
        ;;
    windows-x64)
        require_info features.link_elf false
        require_info features.link_pe true
        ;;
    *)
        echo "unexpected GNU ld test target: $TARGET_PLATFORM" >&2
        exit 1
        ;;
esac

bash scripts/test/package-capabilities.sh "$root" ld

[ -x "$root/bin/ld" ] || {
    echo "GNU ld package is missing bin/ld" >&2
    exit 1
}
"$root/bin/ld" --version

printf 'cup-gnu-ld-functional-payload\n' > "$tmpdir/payload.bin"
"$root/bin/ld" -r -b binary "$tmpdir/payload.bin" -o "$tmpdir/linked.o"
[ -s "$tmpdir/linked.o" ] || {
    echo "GNU ld did not produce a relocatable output" >&2
    exit 1
}
file "$tmpdir/linked.o"

if [ "$HOST_PLATFORM" != "$TARGET_PLATFORM" ]; then
    target_triple="$(info_value platform.target_triple)"
    target_entry="bin/$target_triple-ld"
    require_info entry.target_ld "$target_entry"
    [ -x "$root/$target_entry" ] || {
        echo "cross GNU ld package is missing target-prefixed entry: $target_entry" >&2
        exit 1
    }
    "$root/$target_entry" --version
else
    if grep -q '^entry.target_ld=' "$root/info.txt"; then
        echo "native GNU ld package unexpectedly declares entry.target_ld" >&2
        exit 1
    fi
fi

for path in "$root/bin"/*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    name="$(basename "$path")"
    case "$name" in
        ld|ld.bfd) ;;
        "$(info_value platform.target_triple)-ld")
            [ "$HOST_PLATFORM" != "$TARGET_PLATFORM" ] || {
                echo "native GNU ld package contains unnecessary target-prefixed linker: $name" >&2
                exit 1
            }
            ;;
        *)
            echo "GNU ld package exposes non-linker Binutils payload in bin/: $name" >&2
            exit 1
            ;;
    esac
done

if find "$root" -type f -name 'liblto_plugin.so*' -print -quit | grep -q .; then
    echo "GNU ld package incorrectly owns GCC liblto_plugin.so" >&2
    exit 1
fi

for tool in as ar ranlib strip nm objdump objcopy readelf size strings addr2line c++filt elfedit gprof; do
    if [ -e "$root/bin/$tool" ] || [ -L "$root/bin/$tool" ]; then
        echo "GNU ld package contains unrelated Binutils public tool: $tool" >&2
        exit 1
    fi
done

printf 'GNU ld package tests passed\n'
