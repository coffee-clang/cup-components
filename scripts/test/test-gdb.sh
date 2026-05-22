#!/usr/bin/env bash
set -euo pipefail

source dist/release.env

rm -rf dist/package-test
mkdir -p dist/package-test
tar -xJf "dist/$package_base.tar.xz" -C dist/package-test

root="dist/package-test/$package_base"

bash scripts/test/package-capabilities.sh "$root" gdb
tmpdir="$(mktemp -d /tmp/cup-gdb-test.XXXXXX)"
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

require_executable "$root/bin/gdb"
"$root/bin/gdb" --version
"$root/bin/gdb" --configuration

# Python support is a major GDB capability and is declared by the package metadata.
# Other configure-time libraries are intentionally not asserted here: they are
# packaging details, while this script is an acceptance test for the published tool.
if feature_enabled "features.python" || feature_enabled "config.python" || feature_enabled "contents.uses_python"; then
    "$root/bin/gdb" -q -batch \
        -ex "python import sys, gdb; print(\"python-ok\", sys.version_info[0], sys.version_info[1])" \
        | tee "$tmpdir/gdb-python-output.txt"
    grep -F "python-ok" "$tmpdir/gdb-python-output.txt"
else
    echo "warning: GDB Python support not declared in info.txt"
fi

cat > "$tmpdir/gdb-test.c" <<'C_EOF'
#include <stdio.h>

static int add(int a, int b) {
    return a + b;
}

int main(void) {
    int x = add(20, 22);
    printf("x = %d\n", x);
    return 0;
}
C_EOF

gcc -g -O0 "$tmpdir/gdb-test.c" -o "$tmpdir/gdb-test"
"$root/bin/gdb" -q -batch \
    -ex "set debuginfod enabled off" \
    -ex "file $tmpdir/gdb-test" \
    -ex "break add" \
    -ex "run" \
    -ex "print a" \
    -ex "print b" \
    -ex "backtrace" \
    | tee "$tmpdir/gdb-output.txt"

grep -F '$1 = 20' "$tmpdir/gdb-output.txt"
grep -F '$2 = 22' "$tmpdir/gdb-output.txt"
grep -F "#0" "$tmpdir/gdb-output.txt"
