#!/usr/bin/env bash
set -euo pipefail

source dist/release.env

rm -rf dist/package-test
mkdir -p dist/package-test
tar -xJf "dist/$package_base.tar.xz" -C dist/package-test

root="dist/package-test/$package_base"

bash scripts/test/package-capabilities.sh "$root" valgrind
tmpdir="$(mktemp -d /tmp/cup-valgrind-test.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

info_value() {
    local key="$1"
    local info_file="$root/info.txt"

    if [ ! -f "$info_file" ]; then
        printf '\n'
        return 0
    fi

    awk -F= -v key="$key" '$1 == key { print $2; found=1 } END { if (!found) print "" }' "$info_file"
}

feature_enabled() {
    local key="$1"
    [ "$(info_value "$key")" = "true" ]
}

require_executable() {
    local path="$1"

    if [ ! -x "$path" ]; then
        echo "missing executable: $path" >&2
        exit 1
    fi
}

require_executable "$root/bin/valgrind"
require_executable "$root/bin/vgdb"
"$root/bin/valgrind" --version
"$root/bin/vgdb" --help >"$tmpdir/vgdb-help.txt" 2>&1
if grep -F '/.cup-build/' "$tmpdir/vgdb-help.txt" >/dev/null; then
    echo "vgdb help retains an absolute build/staging prefix" >&2
    cat "$tmpdir/vgdb-help.txt" >&2
    exit 1
fi
"$root/bin/valgrind" --tool=memcheck --help >"$tmpdir/valgrind-help.txt"
grep -A3 "available tools are:" "$tmpdir/valgrind-help.txt"

if feature_enabled "features.mpiwrap"; then
    echo "core Valgrind package unexpectedly declares MPI wrapper support" >&2
    exit 1
fi
if find "$root" -type f -name "libmpiwrap-*" -print -quit | grep -q .; then
    echo "core Valgrind package unexpectedly contains an MPI wrapper" >&2
    exit 1
fi

if feature_enabled "features.gdb_python_frontend"; then
    echo "relocatable core Valgrind package unexpectedly enables the absolute-path GDB Python front end" >&2
    exit 1
fi
if find "$root" -type f -name 'valgrind-monitor.py' -print -quit | grep -q .; then
    echo "relocatable core Valgrind package unexpectedly contains valgrind-monitor.py" >&2
    exit 1
fi
if [ -f "$root/lib/pkgconfig/valgrind.pc" ]; then
    grep -F 'prefix=${pcfiledir}/../..' "$root/lib/pkgconfig/valgrind.pc" >/dev/null
    if grep -F "$root" "$root/lib/pkgconfig/valgrind.pc" >/dev/null; then
        echo "Valgrind pkg-config metadata contains an extracted absolute prefix" >&2
        exit 1
    fi
fi

cat > "$tmpdir/valgrind-leak.c" <<'C_EOF'
#include <stdlib.h>

int main(void) {
    int *p = malloc(sizeof(int));
    *p = 42;
    return 0;
}
C_EOF

gcc -g -O0 "$tmpdir/valgrind-leak.c" -o "$tmpdir/valgrind-leak"
"$root/bin/valgrind" --leak-check=full "$tmpdir/valgrind-leak" 2>&1 | tee "$tmpdir/valgrind-output.txt"
grep "definitely lost: 4 bytes in 1 blocks" "$tmpdir/valgrind-output.txt"

# The Valgrind package uses a relocatable wrapper, so moving the extracted tree is
# part of the package contract and should be tested explicitly.
reloc_root="$tmpdir/valgrind-reloc"
cp -RPp "$root" "$reloc_root"
"$reloc_root/bin/valgrind" --leak-check=full "$tmpdir/valgrind-leak" 2>&1 | tee "$tmpdir/valgrind-reloc-output.txt"
grep "definitely lost: 4 bytes in 1 blocks" "$tmpdir/valgrind-reloc-output.txt"
