#!/usr/bin/env bash
set -euo pipefail

source dist/release.env

rm -rf dist/package-test
mkdir -p dist/package-test
tar -xJf "dist/$package_base.tar.xz" -C dist/package-test

root="dist/package-test/$package_base"
root="$(cd "$root" && pwd)"
unset PYTHONHOME PYTHONPATH || true

bash scripts/test/package-capabilities.sh "$root" gdb
tmpdir="$(mktemp -d /tmp/cup-gdb-test.XXXXXX)"
remote_server_pid=""

cleanup() {
    if [ -n "${remote_server_pid:-}" ]; then
        kill "$remote_server_pid" 2>/dev/null || true
        wait "$remote_server_pid" 2>/dev/null || true
    fi
    rm -rf "$tmpdir"
}
trap cleanup EXIT

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

assert_no_gdb_development_payload() {
    local path
    for path in include lib/cmake lib64/cmake; do
        if [ -e "$root/$path" ] || [ -L "$root/$path" ]; then
            echo "GDB development payload leaked into package: $path" >&2
            exit 1
        fi
    done
    if find "$root" -type f \( -name '*.a' -o -name '*.la' \) -print -quit | grep . >/dev/null; then
        echo 'GDB static/libtool development payload leaked into package' >&2
        exit 1
    fi
}

gdb_python_identity_probe() {
    local candidate="$1"
    local label="$2"
    local out="$tmpdir/gdb-python-$label.txt"
    local expected_version
    local status

    expected_version="$(awk -F= '$1 == "contents.python_runtime.version" { print $2; found=1 } END { if (!found) exit 1 }' "$candidate/info.txt" 2>/dev/null || true)"
    [ -n "$expected_version" ] || {
        echo "GDB package is missing Python runtime provenance: $candidate/info.txt" >&2
        exit 1
    }

    set +e
    env -i HOME="$tmpdir/home-$label" PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        "$candidate/bin/gdb" -q -nx -batch \
        -ex 'set debuginfod enabled off' \
        -ex 'python import sys,gdb; print("PY_PREFIX="+sys.prefix); print("PY_VERSION="+".".join(map(str, sys.version_info[:3]))); print("GDB_DATA="+gdb.parameter("data-directory"))' \
        > "$out" 2>&1
    status=$?
    set -e

    if [ "$status" -ne 0 ] ||
       ! grep -Fx "PY_PREFIX=$candidate" "$out" >/dev/null ||
       ! grep -Fx "PY_VERSION=$expected_version" "$out" >/dev/null ||
       ! grep -Fx "GDB_DATA=$candidate/share/gdb" "$out" >/dev/null; then
        echo "GDB package-owned Python identity probe failed at relocation $label" >&2
        cat "$out" >&2
        exit 1
    fi
}

gdb_remote_debug_probe() {
    local candidate="$1"
    local label="$2"
    local server_out="$tmpdir/gdbserver-$label.txt"
    local client_out="$tmpdir/gdb-remote-$label.txt"
    local port=""
    local attempt=0

    "$candidate/bin/gdbserver" --once 127.0.0.1:0 "$tmpdir/gdb-test" > "$server_out" 2>&1 &
    remote_server_pid=$!

    while [ "$attempt" -lt 100 ]; do
        port="$(sed -n 's/^Listening on port \([0-9][0-9]*\)$/\1/p' "$server_out" | tail -n 1)"
        [ -n "$port" ] && break
        kill -0 "$remote_server_pid" 2>/dev/null || break
        sleep 0.05
        attempt=$((attempt + 1))
    done

    if [ -z "$port" ]; then
        echo "packaged gdbserver did not reach loopback listening state at relocation $label" >&2
        cat "$server_out" >&2
        return 1
    fi

    if ! "$candidate/bin/gdb" -q -nx -batch \
        -ex 'set debuginfod enabled off' \
        -ex "file $tmpdir/gdb-test" \
        -ex "target remote 127.0.0.1:$port" \
        -ex 'break add' \
        -ex 'continue' \
        -ex 'print a' \
        -ex 'print b' \
        -ex 'backtrace' \
        -ex 'continue' \
        > "$client_out" 2>&1; then
        echo "packaged GDB remote-debugging session failed at relocation $label" >&2
        cat "$server_out" "$client_out" >&2
        return 1
    fi

    if ! grep -F '$1 = 20' "$client_out" >/dev/null ||
       ! grep -F '$2 = 22' "$client_out" >/dev/null ||
       ! grep -F '#0' "$client_out" >/dev/null; then
        echo "packaged GDB remote-debugging output was incomplete at relocation $label" >&2
        cat "$server_out" "$client_out" >&2
        return 1
    fi
    if ! wait "$remote_server_pid"; then
        echo "packaged gdbserver exited unsuccessfully at relocation $label" >&2
        cat "$server_out" "$client_out" >&2
        return 1
    fi
    remote_server_pid=""
}

require_executable "$root/bin/gdb"
require_executable "$root/bin/gdbserver"
if ! feature_enabled "features.gdbserver" || ! feature_enabled "features.remote_debugging"; then
    echo "required GDB remote-debugging capability is not fully declared in info.txt" >&2
    exit 1
fi
[ -d "$root/share/gdb" ] || { echo 'missing GDB data directory' >&2; exit 1; }
assert_no_gdb_development_payload
if feature_enabled "features.source_highlight"; then
    [ -f "$root/share/gdb/source-highlight/lang.map" ] || { echo 'missing GDB Source Highlight runtime data' >&2; exit 1; }
fi
gdb_python_identity_probe "$root" A
"$root/bin/gdb" --version
"$root/bin/gdb" --configuration
"$root/bin/gdbserver" --version

# Python support is a major GDB capability and is declared by the package metadata.
# Other configure-time libraries are intentionally not asserted here: they are
# packaging details, while this script is an acceptance test for the published tool.
if ! feature_enabled "features.python" || ! feature_enabled "config.python" || ! feature_enabled "contents.uses_python"; then
    echo "required GDB Python capability is not fully declared in info.txt" >&2
    exit 1
fi
"$root/bin/gdb" -q -batch \
    -ex "python import sys, gdb; print(\"python-ok\", sys.version_info[0], sys.version_info[1])" \
    | tee "$tmpdir/gdb-python-output.txt"
grep -F "python-ok" "$tmpdir/gdb-python-output.txt"

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

# Relocation requires the previous exact root to be physically unavailable.
reloc_b="$tmpdir/relocated-gdb-b"
reloc_c="$tmpdir/relocation c with spaces"
cp -RPp "$root" "$reloc_b"
mv "$root" "$tmpdir/original-gdb-root-disabled"
[ ! -e "$root" ] || { echo 'GDB relocation A root is still available' >&2; exit 1; }

gdb_python_identity_probe "$reloc_b" B
"$reloc_b/bin/gdb" -q -nx -batch \
    -ex 'set debuginfod enabled off' \
    -ex "file $tmpdir/gdb-test" \
    -ex 'break add' -ex run -ex backtrace \
    | tee "$tmpdir/gdb-reloc-b-output.txt"
grep -F '#0' "$tmpdir/gdb-reloc-b-output.txt"

mv "$reloc_b" "$reloc_c"
[ ! -e "$reloc_b" ] || { echo 'GDB relocation B root is still available' >&2; exit 1; }
gdb_python_identity_probe "$reloc_c" C
"$reloc_c/bin/gdb" -q -nx -batch \
    -ex 'set debuginfod enabled off' \
    -ex "file $tmpdir/gdb-test" \
    -ex 'break add' -ex run -ex backtrace \
    | tee "$tmpdir/gdb-reloc-c-output.txt"
grep -F '#0' "$tmpdir/gdb-reloc-c-output.txt"
gdb_remote_debug_probe "$reloc_c" C
