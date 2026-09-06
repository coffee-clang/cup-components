#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Usage:
  $0 <llvm-tool>

Examples:
  $0 clang
  $0 lld
  $0 lldb
  $0 clangd
  $0 clang-format
  $0 clang-tidy
USAGE
}

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi

LLVM_TOOL="$1"
source dist/release.env

tmp_root="$(mktemp -d /tmp/cup-llvm-test.XXXXXX)"
lldb_server_pid=""
lldb_port_reader_pid=""
cleanup() {
    if [ -n "${lldb_port_reader_pid:-}" ]; then
        kill "$lldb_port_reader_pid" 2>/dev/null || true
        wait "$lldb_port_reader_pid" 2>/dev/null || true
    fi
    if [ -n "${lldb_server_pid:-}" ]; then
        kill "$lldb_server_pid" 2>/dev/null || true
        wait "$lldb_server_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp_root"
}
trap cleanup EXIT

rm -rf dist/package-test
mkdir -p dist/package-test
tar -xJf "dist/$package_base.tar.xz" -C dist/package-test

root="dist/package-test/$package_base"
root="$(cd "$root" && pwd)"
host_path="$PATH"
unset PYTHONHOME PYTHONPATH || true
export PATH="$root/bin:$host_path"

macos_sdk_args() {
    if [ "$(uname -s)" = "Darwin" ]; then
        local sdk_path
        sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
        printf '%s\n' -isysroot "$sdk_path"
    fi
}

bash scripts/test/package-capabilities.sh "$root" "$LLVM_TOOL"

require_executable() {
    local path="$1"

    if [ ! -x "$path" ]; then
        echo "missing executable: $path" >&2
        exit 1
    fi
}

run_optional_executable() {
    local path="$1"
    shift

    if [ -x "$path" ]; then
        "$path" "$@"
    else
        echo "warning: optional executable not present: $path"
    fi
}

assert_output_contains() {
    local file_path="$1"
    local pattern="$2"

    if ! grep -E "$pattern" "$file_path" >/dev/null; then
        echo "expected output in $file_path to match: $pattern" >&2
        cat "$file_path" >&2
        exit 1
    fi
}

info_value() {
    local key="$1"
    grep -F "${key}=" "$root/info.txt" | tail -n 1 | sed 's/^[^=]*=//' || true
}

info_bool() {
    [ "$(info_value "$1")" = "true" ]
}

llvm_helper_python_identity_probe() {
    local candidate="$1"
    local label="$2"
    local python="$candidate/libexec/python3"
    local clean_home="$tmp_root/helper-python-home-$label"

    require_executable "$python"
    mkdir -p "$clean_home"
    env -i HOME="$clean_home" PATH="$candidate/bin:/usr/bin:/bin" \
        LANG=C LC_ALL=C TZ=UTC PYTHONDONTWRITEBYTECODE=1 \
        "$python" - "$candidate" <<'PY_HELPER_ID'
import os, sys
root = os.path.realpath(sys.argv[1])
prefix = os.path.realpath(sys.prefix)
stdlib = os.path.realpath(os.path.dirname(os.__file__))
assert prefix == root, (prefix, root)
assert stdlib.startswith(root + os.sep), (stdlib, root)
import json, pathlib
print('LLVM_HELPER_PYTHON_IDENTITY=PASS')
PY_HELPER_ID
}

clang_tidy_helper_probe() {
    local candidate="$1"
    local label="$2"
    local project="$tmp_root/tidy-helper-$label"
    local clean_home="$tmp_root/tidy-helper-home-$label"
    local run_log="$project/run-clang-tidy.log"
    local diff_log="$project/clang-tidy-diff.log"

    rm -rf "$project" "$clean_home"
    mkdir -p "$project" "$clean_home"
    cat > "$project/main.c" <<'C_TIDY_HELPER'
int main(void) {
    return *(int *)0;
}
C_TIDY_HELPER
    cat > "$project/compile_commands.json" <<EOF_TIDY_DB
[
  {
    "directory": "$project",
    "command": "cc -std=c11 -c $project/main.c",
    "file": "$project/main.c"
  }
]
EOF_TIDY_DB

    env -i HOME="$clean_home" PATH="$candidate/bin:/usr/bin:/bin" \
        LANG=C LC_ALL=C TZ=UTC PYTHONDONTWRITEBYTECODE=1 \
        "$candidate/bin/run-clang-tidy" -p "$project" -j 1 \
        -checks=-*,clang-analyzer-core.NullDereference "$project/main.c" \
        > "$run_log" 2>&1
    assert_output_contains "$run_log" 'clang-analyzer-core.NullDereference'

    cat > "$project/change.diff" <<'DIFF_TIDY_HELPER'
diff --git a/main.c b/main.c
--- a/main.c
+++ b/main.c
@@ -1,2 +1,3 @@
 int main(void) {
+    return *(int *)0;
 }
DIFF_TIDY_HELPER
    (
        cd "$project"
        env -i HOME="$clean_home" PATH="$candidate/bin:/usr/bin:/bin" \
            LANG=C LC_ALL=C TZ=UTC PYTHONDONTWRITEBYTECODE=1 \
            "$candidate/bin/clang-tidy-diff" -p1 -path "$project" \
            -checks=-*,clang-analyzer-core.NullDereference \
            < "$project/change.diff"
    ) > "$diff_log" 2>&1
    assert_output_contains "$diff_log" 'clang-analyzer-core.NullDereference'

    printf 'CLANG_TIDY_RUN_HELPER_%s=PASS\n' "$label"
    printf 'CLANG_TIDY_DIFF_HELPER_%s=PASS\n' "$label"
}

require_package_owned_clang_resource_dir() {
    local candidate="$1"
    local resource_dir
    local candidate_real
    local resource_real

    resource_dir="$("$candidate/bin/clang" -print-resource-dir)"
    candidate_real="$(cd "$candidate" && pwd -P)"
    resource_real="$(cd "$resource_dir" && pwd -P)"

    case "$resource_real" in
        "$candidate_real"/*) ;;
        *)
            echo "Clang resource directory is outside package: $resource_real" >&2
            exit 1
            ;;
    esac

    if [ ! -d "$resource_real/include" ]; then
        echo "Clang resource headers are missing: $resource_real/include" >&2
        exit 1
    fi

    printf '%s\n' "$resource_real"
}

prepare_clang_poison_linker() {
    local poison_dir="$1"

    mkdir -p "$poison_dir"
    cat > "$poison_dir/ld.lld" <<'EOF'
#!/usr/bin/env sh
echo "unexpected host ld.lld fallback" >&2
exit 97
EOF
    chmod 0755 "$poison_dir/ld.lld"
}

run_clang_driver_clean() {
    local candidate="$1"
    local driver="$2"
    local clean_home="$3"
    local poison_dir="$4"
    shift 4

    mkdir -p "$clean_home"
    env -i \
        HOME="$clean_home" \
        PATH="$poison_dir:/usr/bin:/bin" \
        LANG=C \
        LC_ALL=C \
        TZ=UTC \
        "$candidate/bin/$driver" "$@"
}

clang_linux_relocation_probe() {
    local candidate="$1"
    local label="$2"
    local poison_dir="$3"
    local clean_home="$tmp_root/clang-home-$label"
    local resource_dir

    "$candidate/bin/clang" --version
    resource_dir="$(require_package_owned_clang_resource_dir "$candidate")"
    echo "clang resource dir ($label): $resource_dir"

    run_clang_driver_clean "$candidate" clang "$clean_home" "$poison_dir" \
        "$tmp_root/clang-test.c" -o "$tmp_root/clang-c-$label"
    "$tmp_root/clang-c-$label" | grep -F "hello clang 42"

    run_clang_driver_clean "$candidate" clang++ "$clean_home" "$poison_dir" \
        "$tmp_root/clang-cpp-test.cpp" -o "$tmp_root/clang-cpp-$label"
    "$tmp_root/clang-cpp-$label" | grep -F "42"

    run_clang_driver_clean "$candidate" clang++ "$clean_home" "$poison_dir" \
        -stdlib=libc++ "$tmp_root/clang-cpp-test.cpp" -o "$tmp_root/clang-libcxx-$label"
    "$tmp_root/clang-libcxx-$label" | grep -F "42"

    run_clang_driver_clean "$candidate" clang "$clean_home" "$poison_dir" \
        -flto -fuse-ld=lld "$tmp_root/clang-test.c" -o "$tmp_root/clang-lto-$label"
    "$tmp_root/clang-lto-$label" | grep -F "hello clang 42"
}


macos_macho_min_version() {
    local path="$1"

    otool -l "$path" | awk '
        $1 == "cmd" { command = $2 }
        command == "LC_BUILD_VERSION" && $1 == "minos" { print $2; exit }
        command == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2; exit }
    '
}

macos_version_at_most() {
    local actual="$1"
    local maximum="$2"

    awk -v actual="$actual" -v maximum="$maximum" 'BEGIN {
        split(actual, a, ".")
        split(maximum, b, ".")
        for (i = 1; i <= 3; i++) {
            av = (a[i] == "" ? 0 : a[i]) + 0
            bv = (b[i] == "" ? 0 : b[i]) + 0
            if (av < bv) exit 0
            if (av > bv) exit 1
        }
        exit 0
    }'
}

macos_version_is() {
    local actual="$1"
    local expected="$2"

    macos_version_at_most "$actual" "$expected" &&
        macos_version_at_most "$expected" "$actual"
}

macos_expected_native_arch() {
    case "$(info_value platform.host)" in
        macos-x64) printf '%s\n' x86_64 ;;
        macos-arm64) printf '%s\n' arm64 ;;
        *) return 1 ;;
    esac
}

macos_test_is_runtime_macho() {
    local path="$1"
    local description

    [ -f "$path" ] || return 1

    # Keep raw bytes out of shell variables. The first probe recognizes a
    # normal ar archive; the textual `file` description also catches fat
    # Mach-O containers whose slices are static archives.
    if LC_ALL=C head -c 8 "$path" 2>/dev/null | grep -Fqx '!<arch>'; then
        return 1
    fi

    description="$(LC_ALL=C file -b "$path" 2>/dev/null || true)"
    case "$description" in
        *archive*) return 1 ;;
        *Mach-O*) return 0 ;;
        *) return 1 ;;
    esac
}
assert_macos_clang_package_contract() {
    local candidate="$1"
    local expected_arch="$2"
    local path
    local archs
    local minos
    local count=0

    for tool in file lipo otool codesign; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "required macOS package inspection tool is missing: $tool" >&2
            exit 1
        }
    done

    while IFS= read -r -d '' path; do
        macos_test_is_runtime_macho "$path" || continue
        count=$((count + 1))

        archs="$(lipo -archs "$path")"
        if [ "$archs" != "$expected_arch" ]; then
            echo "unexpected Mach-O architecture for ${path#"$candidate"/}: $archs (expected $expected_arch)" >&2
            exit 1
        fi

        minos="$(macos_macho_min_version "$path")"
        if [ -z "$minos" ]; then
            echo "macOS deployment floor is missing for ${path#"$candidate"/}" >&2
            exit 1
        fi
        if ! macos_version_at_most "$minos" 15.0; then
            echo "Mach-O deployment floor exceeds macOS 15.0 for ${path#"$candidate"/}: $minos" >&2
            exit 1
        fi

        codesign --verify --strict "$path" >/dev/null 2>&1 || {
            echo "invalid packaged Mach-O signature: ${path#"$candidate"/}" >&2
            exit 1
        }
    done < <(find "$candidate" -type f -print0)

    [ "$count" -gt 0 ] || {
        echo "Clang macOS package contains no Mach-O objects" >&2
        exit 1
    }

    for path in "$candidate/bin/clang" "$candidate/bin/ld64.lld"; do
        require_executable "$path"
        minos="$(macos_macho_min_version "$path")"
        if ! macos_version_is "$minos" 15.0; then
            echo "primary Clang package executable does not encode minos 15.0: ${path#"$candidate"/}: $minos" >&2
            exit 1
        fi
    done

    printf 'MACOS_NATIVE_ARCH=%s\n' "$expected_arch"
    printf 'MACOS_PRIMARY_MINOS=15.0\n'
    printf 'MACOS_DEPENDENCY_FLOOR_NOT_ABOVE_15_0=PASS\n'
    printf 'MACOS_CODESIGN_VERIFY=PASS\n'
}

clang_macos_relocation_probe() {
    local candidate="$1"
    local label="$2"
    local clean_home="$tmp_root/clang-macos-home-$label"
    local resource_dir
    local sdk_args=()

    mapfile -t sdk_args < <(macos_sdk_args)
    mkdir -p "$clean_home"

    "$candidate/bin/clang" --version
    resource_dir="$(require_package_owned_clang_resource_dir "$candidate")"
    echo "clang resource dir ($label): $resource_dir"

    env -i HOME="$clean_home" PATH=/usr/bin:/bin LANG=C LC_ALL=C TZ=UTC \
        "$candidate/bin/clang" "${sdk_args[@]}" \
        "$tmp_root/clang-test.c" -o "$tmp_root/clang-macos-c-$label"
    "$tmp_root/clang-macos-c-$label" | grep -F "hello clang 42"

    env -i HOME="$clean_home" PATH=/usr/bin:/bin LANG=C LC_ALL=C TZ=UTC \
        "$candidate/bin/clang++" "${sdk_args[@]}" \
        "$tmp_root/clang-cpp-test.cpp" -o "$tmp_root/clang-macos-cpp-$label"
    "$tmp_root/clang-macos-cpp-$label" | grep -F "42"

    env -i HOME="$clean_home" PATH=/usr/bin:/bin LANG=C LC_ALL=C TZ=UTC \
        "$candidate/bin/clang" "${sdk_args[@]}" -flto \
        -fuse-ld="$candidate/bin/ld64.lld" \
        "$tmp_root/clang-test.c" -o "$tmp_root/clang-macos-lto-$label"
    "$tmp_root/clang-macos-lto-$label" | grep -F "hello clang 42"
}

run_lldb_clean() {
    local candidate="$1"
    shift
    local clean_home="$tmp_root/clean-home"
    mkdir -p "$clean_home"
    env -i HOME="$clean_home" PATH=/usr/bin:/bin LANG=C LC_ALL=C TZ=UTC \
        PYTHONDONTWRITEBYTECODE=1 "$candidate/bin/lldb" "$@"
}

lldb_remote_debug_probe() {
    local candidate="$1"
    local label="$2"
    local work="$tmp_root/lldb-remote-$label"
    local fifo="$work/port.fifo"
    local port_file="$work/port"
    local marker="$work/inferior.done"
    local server_out="$work/server.txt"
    local client_out="$work/client.txt"
    local port=""
    local attempt=0
    local reader_status

    mkdir -p "$work"
    cat > "$work/remote-test.c" <<'C_REMOTE_EOF'
#include <stdio.h>

volatile int cup_lldb_remote_value = 37;

__attribute__((noinline)) static void cup_lldb_remote_stop(int value) {
    __asm__ volatile("" : : "r"(value) : "memory");
}

int main(int argc, char **argv) {
    int value = cup_lldb_remote_value + 5;
    cup_lldb_remote_stop(value);
    if (argc > 1) {
        FILE *marker = fopen(argv[1], "w");
        if (!marker) return 3;
        fprintf(marker, "LLDB_REMOTE_DONE=%d\\n", value);
        if (fclose(marker) != 0) return 4;
    }
    return value == 42 ? 0 : 2;
}
C_REMOTE_EOF
    cc -g -O0 "$work/remote-test.c" -o "$work/remote-test"

    rm -f "$fifo" "$port_file" "$marker"
    mkfifo "$fifo"
    cat "$fifo" > "$port_file" &
    lldb_port_reader_pid=$!
    env -i HOME="$tmp_root/lldb-server-home-$label" PATH=/usr/bin:/bin \
        LANG=C LC_ALL=C TZ=UTC \
        "$candidate/bin/lldb-server" gdbserver \
        --named-pipe "$fifo" 127.0.0.1:0 -- "$work/remote-test" "$marker" \
        > "$server_out" 2>&1 &
    lldb_server_pid=$!

    while [ "$attempt" -lt 160 ]; do
        if ! kill -0 "$lldb_server_pid" 2>/dev/null; then
            break
        fi
        if ! kill -0 "$lldb_port_reader_pid" 2>/dev/null; then
            break
        fi
        sleep 0.05
        attempt=$((attempt + 1))
    done

    if kill -0 "$lldb_port_reader_pid" 2>/dev/null; then
        echo "packaged lldb-server did not publish its structured port at relocation $label" >&2
        cat "$server_out" >&2
        return 1
    fi
    set +e
    wait "$lldb_port_reader_pid"
    reader_status=$?
    set -e
    lldb_port_reader_pid=""
    [ "$reader_status" -eq 0 ] && [ -s "$port_file" ] || {
        echo "packaged lldb-server port publication failed at relocation $label" >&2
        cat "$server_out" >&2
        return 1
    }

    port="$(LC_ALL=C tr -d '\000\r\n\t ' < "$port_file")"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
        echo "packaged lldb-server published an invalid port at relocation $label: $port" >&2
        return 1
    }
    rm -f "$fifo"

    cat > "$work/client.cmd" <<EOF_REMOTE_CMD
 target create '$work/remote-test'
 gdb-remote 127.0.0.1:$port
 breakpoint set -n cup_lldb_remote_stop
 continue
 expression -- (int)(cup_lldb_remote_value + 5)
 process detach
 quit
EOF_REMOTE_CMD
    if ! run_lldb_clean "$candidate" -b -s "$work/client.cmd" > "$client_out" 2>&1; then
        echo "packaged LLDB remote-debugging session failed at relocation $label" >&2
        cat "$server_out" "$client_out" >&2
        return 1
    fi
    grep -E '\(int\).*42|=[[:space:]]*42' "$client_out" >/dev/null || {
        echo "packaged LLDB remote-debugging expression was not observed at relocation $label" >&2
        cat "$client_out" >&2
        return 1
    }

    attempt=0
    while [ "$attempt" -lt 200 ]; do
        if [ -f "$marker" ] && grep -Fx 'LLDB_REMOTE_DONE=42' "$marker" >/dev/null 2>&1; then
            break
        fi
        kill -0 "$lldb_server_pid" 2>/dev/null || break
        sleep 0.05
        attempt=$((attempt + 1))
    done
    [ -f "$marker" ] && grep -Fx 'LLDB_REMOTE_DONE=42' "$marker" >/dev/null || {
        echo "packaged LLDB remote inferior did not complete after detach at relocation $label" >&2
        cat "$server_out" "$client_out" >&2
        return 1
    }
    if ! wait "$lldb_server_pid"; then
        lldb_server_pid=""
        echo "packaged lldb-server exited unsuccessfully at relocation $label" >&2
        cat "$server_out" "$client_out" >&2
        return 1
    fi
    lldb_server_pid=""
    echo "LLDB remote-debugging session passed at relocation $label on port $port"
}


lldb_identity_probe() {
    local candidate="$1"
    local label="$2"
    local out="$tmp_root/lldb-identity-$label.txt"
    local json="$tmp_root/lldb-interpreter-$label.json"
    local clean_home="$tmp_root/clean-home-$label"
    local python_entry
    local python_version
    local lldb_pythonpath
    local clang_resource

    python_entry="$(awk -F= '$1 == "config.python_executable" { print $2; exit }' "$candidate/info.txt")"
    [ -n "$python_entry" ] || { echo 'LLDB packaged Python executable is not declared' >&2; exit 1; }
    python_version="${python_entry#bin/python}"
    clang_resource="$(find "$candidate/lib/clang" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)"
    [ -n "$clang_resource" ] || { echo 'LLDB Clang resource directory is missing' >&2; exit 1; }
    mkdir -p "$clean_home"

    env -i HOME="$clean_home" PATH=/usr/bin:/bin LANG=C LC_ALL=C TZ=UTC \
        PYTHONDONTWRITEBYTECODE=1 "$candidate/$python_entry" - <<'PY_ID' > "$out"
import lldb, sys
print('PY_PREFIX='+sys.prefix)
print('PY_EXEC='+sys.executable)
print('LLDB_FILE='+lldb.__file__)
d=lldb.SBDebugger.Create(); print('SBDEBUGGER_VALID='+str(d.IsValid())); lldb.SBDebugger.Destroy(d)
PY_ID
    grep -Fx "PY_PREFIX=$candidate" "$out" >/dev/null
    grep -Fx "PY_EXEC=$candidate/$python_entry" "$out" >/dev/null
    lldb_pythonpath="$(sed -n 's/^LLDB_FILE=//p' "$out" | sed 's#/lldb/.*$##' | head -n 1)"
    case "$lldb_pythonpath" in
        "$candidate/lib/python$python_version/site-packages"|"$candidate/lib/python$python_version/dist-packages") ;;
        *)
            echo "LLDB Python module escaped the package-owned Python directories: $lldb_pythonpath" >&2
            exit 1
            ;;
    esac
    grep -Fx 'SBDEBUGGER_VALID=True' "$out" >/dev/null

    run_lldb_clean "$candidate" --print-script-interpreter-info > "$json"
    env -i HOME="$clean_home" PATH=/usr/bin:/bin LANG=C LC_ALL=C TZ=UTC \
        "$candidate/$python_entry" - "$json" "$candidate" "$python_entry" "$lldb_pythonpath" <<'PY_INFO'
import json, os, sys
with open(sys.argv[1], encoding='utf-8') as f:
    info=json.load(f)
root, python_entry, lldb_pythonpath=sys.argv[2:5]
expected={
    'language':'python',
    'prefix':root,
    'executable':root+'/'+python_entry,
    'lldb-pythonpath':lldb_pythonpath,
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f'{key}: expected {value!r}, got {info.get(key)!r}')
if not os.path.isfile(info['executable']) or not os.access(info['executable'], os.X_OK):
    raise SystemExit('interpreter executable is missing or not executable')
PY_INFO

    run_lldb_clean "$candidate" -b \
        -o 'script import lldb; print("CLANG_DIR="+str(lldb.SBHostOS.GetLLDBPath(lldb.ePathTypeClangDir)))' \
        -o quit > "$tmp_root/lldb-clang-dir-$label.txt" 2>&1
    grep -Fx "CLANG_DIR=$clang_resource" "$tmp_root/lldb-clang-dir-$label.txt" >/dev/null
    [ -d "$clang_resource/include" ] || { echo 'LLDB Clang resource headers missing' >&2; exit 1; }
}


assert_no_llvm_development_payload() {
    local path
    local lib_dir
    local archive
    local base

    for path in \
        include/llvm include/llvm-c include/clang include/clang-c \
        include/lld include/lldb include/mach-o lib/cmake lib64/cmake; do
        if [ -e "$root/$path" ] || [ -L "$root/$path" ]; then
            echo "LLVM development payload leaked into package: $path" >&2
            exit 1
        fi
    done

    for lib_dir in "$root/lib" "$root/lib64"; do
        [ -d "$lib_dir" ] || continue

        for path in \
            "$lib_dir"/libLTO.so* "$lib_dir"/libLTO.dylib* \
            "$lib_dir"/libRemarks.so* "$lib_dir"/libRemarks.dylib* \
            "$lib_dir"/libclang.so* "$lib_dir"/libclang.dylib* \
            "$lib_dir"/libclang-cpp.so* "$lib_dir"/libclang-cpp.dylib*; do
            if [ -e "$path" ] || [ -L "$path" ]; then
                echo "LLVM shared development API leaked into package: ${path#"$root/"}" >&2
                exit 1
            fi
        done

        while IFS= read -r -d '' archive; do
            base="$(basename "$archive")"
            case "$base" in
                libc++.a|libc++abi.a|libc++experimental.a|libunwind.a|libclang_rt.*)
                    continue
                    ;;
            esac
            echo "LLVM static development archive leaked into package: ${archive#"$root/"}" >&2
            exit 1
        done < <(find "$lib_dir" ! -path "$lib_dir" -prune -type f -name '*.a' -print0)
    done
}

assert_no_llvm_development_payload

case "$LLVM_TOOL" in
    clang)
        require_executable "$root/bin/clang"
        require_executable "$root/bin/clang++"
        require_executable "$root/bin/ld.lld"

        "$root/bin/clang" --version
        "$root/bin/clang++" --version
        "$root/bin/ld.lld" --version

        resource_dir="$(require_package_owned_clang_resource_dir "$root")"
        echo "clang resource dir: $resource_dir"

        if [ "$(uname -s)" = "Linux" ]; then
            [ -f "$root/bin/clang++.cfg" ] || {
                echo "Linux Clang packaged libc++ driver config is missing" >&2
                exit 1
            }
            grep -Fx -- '-L<CFGDIR>/../lib' "$root/bin/clang++.cfg" >/dev/null || {
                echo "Linux Clang C++ driver config is not package-relative" >&2
                exit 1
            }
            clang_poison="$tmp_root/clang-poison-linker"
            prepare_clang_poison_linker "$clang_poison"
        fi

        cat > "$tmp_root/clang-test.c" <<'C_EOF'
#include <stdio.h>

static int add(int a, int b) {
    return a + b;
}

int main(void) {
    printf("hello clang %d\n", add(20, 22));
    return 0;
}
C_EOF
        mapfile -t sdk_args < <(macos_sdk_args)
        if [ "$(uname -s)" = "Linux" ]; then
            run_clang_driver_clean "$root" clang "$tmp_root/clang-home-A" "$clang_poison" \
                "$tmp_root/clang-test.c" -o "$tmp_root/clang-test"
        else
            "$root/bin/clang" "${sdk_args[@]}" "$tmp_root/clang-test.c" -o "$tmp_root/clang-test"
        fi
        "$tmp_root/clang-test" | grep -F "hello clang 42"

        if [ "$(uname -s)" = "Darwin" ]; then
            require_executable "$root/bin/ld64.lld"
            "$root/bin/clang" "${sdk_args[@]}" -fuse-ld="$root/bin/ld64.lld" \
                "$tmp_root/clang-test.c" -o "$tmp_root/clang-lld-test"
            "$tmp_root/clang-lld-test" | grep -F "hello clang 42"

            "$root/bin/clang" "${sdk_args[@]}" -flto -fuse-ld="$root/bin/ld64.lld" \
                "$tmp_root/clang-test.c" -o "$tmp_root/clang-lto-test"
            "$tmp_root/clang-lto-test" | grep -F "hello clang 42"
        elif [ "$(uname -s)" = "Linux" ]; then
            run_clang_driver_clean "$root" clang "$tmp_root/clang-home-A" "$clang_poison" \
                -fuse-ld=lld "$tmp_root/clang-test.c" -o "$tmp_root/clang-lld-test"
            "$tmp_root/clang-lld-test" | grep -F "hello clang 42"

            run_clang_driver_clean "$root" clang "$tmp_root/clang-home-A" "$clang_poison" \
                -flto -fuse-ld=lld "$tmp_root/clang-test.c" -o "$tmp_root/clang-lto-test"
            "$tmp_root/clang-lto-test" | grep -F "hello clang 42"
        else
            "$root/bin/clang" -fuse-ld=lld "$tmp_root/clang-test.c" -o "$tmp_root/clang-lld-test"
            "$tmp_root/clang-lld-test" | grep -F "hello clang 42"

            "$root/bin/clang" -flto -fuse-ld=lld "$tmp_root/clang-test.c" -o "$tmp_root/clang-lto-test"
            "$tmp_root/clang-lto-test" | grep -F "hello clang 42"
        fi

        cat > "$tmp_root/clang-cpp-test.cpp" <<'CPP_EOF'
#include <iostream>
#include <vector>

int main() {
    std::vector<int> values = {20, 22};
    std::cout << (values[0] + values[1]) << "\n";
    return 0;
}
CPP_EOF
        mapfile -t sdk_args < <(macos_sdk_args)
        if [ "$(uname -s)" = "Linux" ]; then
            run_clang_driver_clean "$root" clang++ "$tmp_root/clang-home-A" "$clang_poison" \
                "$tmp_root/clang-cpp-test.cpp" -o "$tmp_root/clang-cpp-test"
        else
            "$root/bin/clang++" "${sdk_args[@]}" "$tmp_root/clang-cpp-test.cpp" -o "$tmp_root/clang-cpp-test"
        fi
        "$tmp_root/clang-cpp-test" | grep -F "42"

        if ! info_bool features.cxx_runtime; then
            echo "required packaged Clang C++ runtime is not declared" >&2
            exit 1
        fi
        if [ "$(uname -s)" = "Linux" ]; then
            run_clang_driver_clean "$root" clang++ "$tmp_root/clang-home-A" "$clang_poison" \
                -stdlib=libc++ "$tmp_root/clang-cpp-test.cpp" -o "$tmp_root/clang-libcxx-test"
            "$tmp_root/clang-libcxx-test" | grep -F "42"
        elif [ "$(uname -s)" != "Darwin" ]; then
            "$root/bin/clang++" -stdlib=libc++ "$tmp_root/clang-cpp-test.cpp" -o "$tmp_root/clang-libcxx-test"
            "$tmp_root/clang-libcxx-test" | grep -F "42"
        fi

        if info_bool features.asan; then
            cat > "$tmp_root/asan-test.c" <<'ASAN_C_EOF'
#include <stdlib.h>

int main(void) {
    int *value = (int *)malloc(sizeof(int));
    free(value);
    return *value;
}
ASAN_C_EOF
            if [ "$(uname -s)" = "Linux" ]; then
                asan_compile=(run_clang_driver_clean "$root" clang "$tmp_root/clang-home-A" "$clang_poison")
            else
                asan_compile=("$root/bin/clang" "${sdk_args[@]}")
            fi
            if "${asan_compile[@]}" -g -O0 -fsanitize=address "$tmp_root/asan-test.c" -o "$tmp_root/asan-test"; then
                set +e
                ASAN_OPTIONS=abort_on_error=0:detect_leaks=0 \
                    "$tmp_root/asan-test" >"$tmp_root/asan-output.txt" 2>&1
                asan_status=$?
                set -e
                if [ "$asan_status" -eq 0 ]; then
                    echo "ASan test unexpectedly succeeded" >&2
                    cat "$tmp_root/asan-output.txt" >&2
                    exit 1
                fi
                assert_output_contains "$tmp_root/asan-output.txt" 'AddressSanitizer|heap-use-after-free'
                echo "ASan produced the expected diagnostic and non-zero exit status"
            else
                echo "ASan feature is declared but ASan compile/link failed" >&2
                exit 1
            fi
        else
            echo "required Clang ASan runtime is not declared; ASan test cannot run" >&2
            exit 1
        fi
        ;;
    lld)
        require_executable "$root/bin/ld.lld"

        # lld is a generic driver and may exit with a diagnostic when invoked directly.
        # Test the concrete frontends instead.
        "$root/bin/ld.lld" --version
        run_optional_executable "$root/bin/lld-link" --version
        run_optional_executable "$root/bin/wasm-ld" --version
        run_optional_executable "$root/bin/ld64.lld" --version

        cat > "$tmp_root/lld-test.c" <<'C_EOF'
#include <stdio.h>

int main(void) {
    printf("hello lld\n");
    return 0;
}
C_EOF
        if [ "$(uname -s)" = "Darwin" ]; then
            require_executable "$root/bin/ld64.lld"
            cc -fuse-ld="$root/bin/ld64.lld" "$tmp_root/lld-test.c" -o "$tmp_root/lld-test"
            "$tmp_root/lld-test" | grep -F "hello lld"
        else
            cc -B"$root/bin" -fuse-ld=lld "$tmp_root/lld-test.c" -o "$tmp_root/lld-test"
            "$tmp_root/lld-test" | grep -F "hello lld"
        fi
        ;;
    lldb)
        require_executable "$root/bin/lldb"
        if [ "$(info_value platform.host)" != windows-x64 ]; then
            lldb_python_entry="$(info_value config.python_executable)"
            [ -n "$lldb_python_entry" ] || { echo 'LLDB packaged Python executable is not declared' >&2; exit 1; }
            require_executable "$root/$lldb_python_entry"
        fi
        if [ "$(info_value platform.host)" != windows-x64 ]; then
            [ "$(info_value contents.clang_resources)" = true ] || { echo 'LLDB package-owned Clang resources not declared' >&2; exit 1; }
            lldb_identity_probe "$root" A
        fi
        if info_bool features.process_launch; then
            require_executable "$root/bin/lldb-argdumper"
        fi
        if info_bool features.lldb_dap; then
            require_executable "$root/bin/lldb-dap"
        fi
        if info_bool features.lldb_server; then
            require_executable "$root/bin/lldb-server"
            info_bool features.remote_debugging || {
                echo 'LLDB lldb-server is present but remote-debugging capability is not declared' >&2
                exit 1
            }
        elif info_bool features.remote_debugging; then
            echo 'LLDB remote-debugging capability is declared without lldb-server' >&2
            exit 1
        fi

        "$root/bin/lldb" --version
        "$root/bin/lldb" -b -o "script import sys; print('python-ok', sys.version_info[0], sys.version_info[1])" -o quit

        cat > "$tmp_root/lldb-test.c" <<'C_EOF'
#include <stdio.h>

static int cup_lldb_test_add_unique(int a, int b) {
    return a + b;
}

int main(void) {
    int x = cup_lldb_test_add_unique(20, 22);
    printf("x = %d\n", x);
    return 0;
}
C_EOF
        cc -g -O0 "$tmp_root/lldb-test.c" -o "$tmp_root/lldb-test"

        # GitHub-hosted Docker jobs normally do not have the ptrace/personality
        # privileges needed to launch an inferior under LLDB. Validate that LLDB
        # can create the target and inspect symbols, then attempt a launch only
        # when the runner allows it.
        "$root/bin/lldb" -b \
            -o "target create $tmp_root/lldb-test" \
            -o "breakpoint set --name cup_lldb_test_add_unique" \
            -o "image lookup -n cup_lldb_test_add_unique" \
            -o "quit" 2>&1 | tee "$tmp_root/lldb-output.txt"
        grep -F "Breakpoint" "$tmp_root/lldb-output.txt"
        grep -F "cup_lldb_test_add_unique" "$tmp_root/lldb-output.txt"

        if "$root/bin/lldb" -b \
            -o "settings set target.disable-aslr false" \
            -o "target create $tmp_root/lldb-test" \
            -o "breakpoint set --name cup_lldb_test_add_unique" \
            -o "run" \
            -o "frame info" \
            -o "frame variable a" \
            -o "frame variable b" \
            -o "quit" >"$tmp_root/lldb-launch-output.txt" 2>&1; then
            grep -F "cup_lldb_test_add_unique" "$tmp_root/lldb-launch-output.txt"
            grep -F "(int) a = 20" "$tmp_root/lldb-launch-output.txt"
            grep -F "(int) b = 22" "$tmp_root/lldb-launch-output.txt"
        elif grep -E "personality set failed|Operation not permitted|ptrace|not permitted" "$tmp_root/lldb-launch-output.txt" >/dev/null; then
            echo "warning: LLDB inferior launch skipped because the runner forbids debugging privileges"
            cat "$tmp_root/lldb-launch-output.txt"
        else
            cat "$tmp_root/lldb-launch-output.txt" >&2
            exit 1
        fi
        ;;
    clangd)
        require_executable "$root/bin/clangd"
        info_bool contents.clang_resources || { echo "clangd package does not declare package-owned Clang resources" >&2; exit 1; }
        info_bool features.resource_dir || { echo "clangd package does not declare resource-dir capability" >&2; exit 1; }
        for forbidden in \
            include/llvm \
            include/llvm-c \
            include/clang \
            include/clang-c \
            include/clang-tidy \
            lib/cmake \
            lib64/cmake \
            lib/libear \
            lib/libscanbuild \
            libexec \
            share/clang \
            share/clang-doc \
            share/opt-viewer \
            share/scan-build \
            share/scan-view; do
            [ ! -e "$root/$forbidden" ] && [ ! -L "$root/$forbidden" ] || {
                echo "non-runtime sibling/development payload leaked into clangd package: $forbidden" >&2
                exit 1
            }
        done
        [ ! -e "$root/share/man/man1/scan-build.1" ] && [ ! -L "$root/share/man/man1/scan-build.1" ] || {
            echo "sibling scan-build manpage leaked into clangd package" >&2
            exit 1
        }
        while IFS= read -r -d '' candidate; do
            case "$(basename "$candidate")" in
                clangd|clangd-indexer) ;;
                *) echo "unexpected sibling executable leaked into clangd package: $candidate" >&2; exit 1 ;;
            esac
        done < <(find "$root/bin" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0)
        if find "$root/lib" "$root/lib64" -maxdepth 1 -type f \
            \( -name 'libLLVM.so*' -o -name 'libLLVM.dylib*' \
               -o -name 'libclang.so*' -o -name 'libclang.dylib*' -o -name 'libclang.*.dylib' \
               -o -name 'libclang-cpp.so*' -o -name 'libclang-cpp.dylib*' -o -name 'libclang-cpp.*.dylib' \
               -o -name 'libRemarks.so*' -o -name 'libRemarks.dylib*' -o -name 'libRemarks.*.dylib' \
               -o -name 'libClangdXPCLib.so*' -o -name 'libClangdXPCLib.dylib*' -o -name 'libClangdXPCLib.*.dylib' \) \
            -print -quit 2>/dev/null | grep -q .; then
            echo "LLVM/Clang shared development SDK leaked into clangd package" >&2
            exit 1
        fi
        for forbidden in include share libexec; do
            [ ! -e "$root/$forbidden" ] && [ ! -L "$root/$forbidden" ] || {
                echo "unexpected non-runtime top-level payload leaked into clangd package: $forbidden" >&2
                exit 1
            }
        done

        clangd_resource_root=""
        for candidate in "$root/lib/clang"/*; do
            [ -d "$candidate" ] || continue
            [ -z "$clangd_resource_root" ] || { echo "multiple clangd resource directories found" >&2; exit 1; }
            clangd_resource_root="$candidate"
        done
        [ -n "$clangd_resource_root" ] || { echo "clangd resource directory missing" >&2; exit 1; }
        [ -f "$clangd_resource_root/include/stddef.h" ] || { echo "clangd built-in stddef.h missing" >&2; exit 1; }

        "$root/bin/clangd" --version
        project_dir="$tmp_root/clangd-project"
        mkdir -p "$project_dir"
        cat > "$project_dir/main.c" <<'C_EOF'
#include <stddef.h>

int main(void) {
    size_t value = 0;
    return (int)value;
}
C_EOF
        cat > "$project_dir/compile_commands.json" <<EOF_JSON
[
  {
    "directory": "$project_dir",
    "command": "cc -std=c11 -I$project_dir main.c",
    "file": "$project_dir/main.c"
  }
]
EOF_JSON
        "$root/bin/clangd" --check="$project_dir/main.c" 2>&1 | tee "$tmp_root/clangd-output.txt"
        assert_output_contains "$tmp_root/clangd-output.txt" "All checks completed|Testing on source file"
        ;;
    clang-format)
        require_executable "$root/bin/clang-format"

        "$root/bin/clang-format" --version

        if info_bool features.git_clang_format || [ -e "$root/bin/git-clang-format" ] || [ -L "$root/bin/git-clang-format" ]; then
            echo 'clang-format package retained git-clang-format despite the standalone formatter contract' >&2
            exit 1
        fi
        [ "$(info_value contents.python_runtime)" != packaged ] || {
            echo 'clang-format package retained Python solely for a removed Git helper' >&2
            exit 1
        }
        for forbidden in include share libexec; do
            [ ! -e "$root/$forbidden" ] && [ ! -L "$root/$forbidden" ] || {
                echo "non-runtime sibling/development payload leaked into clang-format package: $forbidden" >&2
                exit 1
            }
        done

        printf "%s\n" "int main( void ){return 0;}" > "$tmp_root/format-test.c"
        "$root/bin/clang-format" "$tmp_root/format-test.c" | tee "$tmp_root/format-output.c"
        grep -F "int main(void)" "$tmp_root/format-output.c"

        cat > "$tmp_root/style-test.c" <<'C_EOF'
int main(void) {
return 0;
}
C_EOF
        "$root/bin/clang-format" \
            -style="{BasedOnStyle: LLVM, IndentWidth: 4, AllowShortFunctionsOnASingleLine: None}" \
            "$tmp_root/style-test.c" | tee "$tmp_root/style-output.c"
        grep -F "    return 0;" "$tmp_root/style-output.c"

        project_dir="$tmp_root/format-project"
        mkdir -p "$project_dir"
        cat > "$project_dir/.clang-format" <<'STYLE_EOF'
BasedOnStyle: LLVM
IndentWidth: 3
AllowShortFunctionsOnASingleLine: None
STYLE_EOF
        cat > "$project_dir/main.c" <<'C_EOF'
int main(void) {
return 0;
}
C_EOF
        (
            cd "$project_dir"
            "$root/bin/clang-format" main.c
        ) | tee "$tmp_root/project-format-output.c"
        grep -F "   return 0;" "$tmp_root/project-format-output.c"

        printf "%s\n" "int main( void ){return 0;}" > "$tmp_root/bad-format.c"
        if "$root/bin/clang-format" --dry-run --Werror "$tmp_root/bad-format.c" >"$tmp_root/format-dryrun.txt" 2>&1; then
            echo "clang-format dry-run unexpectedly succeeded on unformatted file" >&2
            cat "$tmp_root/format-dryrun.txt" >&2
            exit 1
        fi

        "$root/bin/clang-format" --assume-filename=test.cpp "$tmp_root/format-test.c" >/dev/null
        ;;
    clang-tidy)
        require_executable "$root/bin/clang-tidy"
        require_executable "$root/bin/clang-apply-replacements"
        require_executable "$root/bin/run-clang-tidy"
        require_executable "$root/bin/clang-tidy-diff"
        require_executable "$root/libexec/python3"
        [ -f "$root/libexec/llvm-python-scripts/run-clang-tidy.py" ] || { echo "run-clang-tidy implementation missing" >&2; exit 1; }
        [ -f "$root/libexec/llvm-python-scripts/clang-tidy-diff.py" ] || { echo "clang-tidy-diff implementation missing" >&2; exit 1; }
        [ ! -e "$root/include" ] || { echo "development headers leaked into clang-tidy package" >&2; exit 1; }
        [ ! -e "$root/share" ] || { echo "non-deliberate share payload leaked into clang-tidy package" >&2; exit 1; }
        for forbidden in analyze-cc analyze-c++ intercept-cc intercept-c++ ccc-analyzer c++-analyzer; do
            [ ! -e "$root/libexec/$forbidden" ] || {
                echo "scan-build helper leaked into clang-tidy package: $forbidden" >&2
                exit 1
            }
        done
        if find "$root/lib" -type d -name __pycache__ -print -quit 2>/dev/null | grep -q .; then
            echo 'Python __pycache__ payload leaked into clang-tidy package' >&2
            exit 1
        fi

        "$root/bin/clang-tidy" --version
        "$root/bin/clang-apply-replacements" --version
        llvm_helper_python_identity_probe "$root" A
        clang_tidy_helper_probe "$root" A
        "$root/bin/clang-tidy" --list-checks "--checks=clang-analyzer-*" | tee "$tmp_root/tidy-checks.txt"
        grep -F "clang-analyzer-core" "$tmp_root/tidy-checks.txt"
        cat > "$tmp_root/tidy-test.c" <<'C_EOF'
#include <stddef.h>
int main(void) {
    return (int)sizeof(size_t);
}
C_EOF
        "$root/bin/clang-tidy" "--checks=clang-analyzer-*" "$tmp_root/tidy-test.c" -- -std=c11
        ;;
    *)
        echo "unsupported LLVM tool: $LLVM_TOOL" >&2
        exit 2
        ;;
esac

# Relocation is exercised with a real tool operation, not only file existence.
reloc_root="$tmp_root/relocated-$LLVM_TOOL"
cp -RPp "$root" "$reloc_root"
unset PYTHONHOME PYTHONPATH || true
export PATH="$reloc_root/bin:$host_path"
case "$LLVM_TOOL" in
    clang)
        mapfile -t sdk_args < <(macos_sdk_args)
        if [ "$(uname -s)" = "Linux" ]; then
            # A must disappear before B, and B before C. C contains real spaces.
            rm -rf "$reloc_root"
            reloc_b="$tmp_root/relocated-clang-b"
            reloc_c="$tmp_root/relocation c with spaces"
            cp -RPp "$root" "$reloc_b"
            mv "$root" "$tmp_root/original-clang-root-disabled"
            [ ! -e "$root" ] || {
                echo "Clang relocation A root is still available" >&2
                exit 1
            }

            clang_linux_relocation_probe "$reloc_b" B "$clang_poison"

            mv "$reloc_b" "$reloc_c"
            [ ! -e "$reloc_b" ] || {
                echo "Clang relocation B root is still available" >&2
                exit 1
            }

            clang_linux_relocation_probe "$reloc_c" C "$clang_poison"
        elif [ "$(uname -s)" = "Darwin" ]; then
            # macOS must prove the same relocation model: A unavailable before B,
            # B unavailable before C, and C contains real spaces.
            rm -rf "$reloc_root"
            reloc_b="$tmp_root/relocated-clang-macos-b"
            reloc_c="$tmp_root/relocation clang macos c with real spaces"
            expected_arch="$(macos_expected_native_arch)" || {
                echo "unsupported Clang macOS package host: $(info_value platform.host)" >&2
                exit 1
            }

            assert_macos_clang_package_contract "$root" "$expected_arch"

            cp -RPp "$root" "$reloc_b"
            mv "$root" "$tmp_root/original-clang-macos-root-disabled"
            [ ! -e "$root" ] || {
                echo "Clang macOS relocation A root is still available" >&2
                exit 1
            }

            clang_macos_relocation_probe "$reloc_b" B

            mv "$reloc_b" "$reloc_c"
            [ ! -e "$reloc_b" ] || {
                echo "Clang macOS relocation B root is still available" >&2
                exit 1
            }

            clang_macos_relocation_probe "$reloc_c" C
            assert_macos_clang_package_contract "$reloc_c" "$expected_arch"
            printf 'CLANG_MACOS_RELOCATION_A_TO_B_TO_C=PASS\n'
            printf 'CLANG_MACOS_REAL_SPACES=PASS\n'
        else
            "$reloc_root/bin/clang" -flto -fuse-ld=lld "$tmp_root/clang-test.c" \
                -o "$tmp_root/clang-relocated-test"
            "$tmp_root/clang-relocated-test" | grep -F "hello clang 42"
        fi
        ;;
    lld)
        "$reloc_root/bin/ld.lld" --version
        if [ "$(uname -s)" = "Darwin" ]; then
            require_executable "$reloc_root/bin/ld64.lld"
            cc -fuse-ld="$reloc_root/bin/ld64.lld" "$tmp_root/lld-test.c" -o "$tmp_root/lld-relocated-test"
            "$tmp_root/lld-relocated-test" | grep -F "hello lld"
        else
            cc -B"$reloc_root/bin" -fuse-ld=lld "$tmp_root/lld-test.c" -o "$tmp_root/lld-relocated-test"
            "$tmp_root/lld-relocated-test" | grep -F "hello lld"
        fi
        ;;
    lldb)
        if [[ "$(info_value platform.host)" == linux-* || "$(info_value platform.host)" == macos-* ]]; then
            # LLDB carries package-owned Python/resource state on POSIX hosts. A
            # must disappear before B, and B before C, so absolute fallbacks
            # cannot satisfy the identity checks. C contains real spaces.
            rm -rf "$reloc_root"
            reloc_b="$tmp_root/relocated-lldb-b"
            reloc_c="$tmp_root/relocation c with spaces"
            cp -RPp "$root" "$reloc_b"
            mv "$root" "$tmp_root/original-lldb-root-disabled"
            [ ! -e "$root" ] || { echo 'LLDB relocation A root is still available' >&2; exit 1; }
            lldb_identity_probe "$reloc_b" B
            run_lldb_clean "$reloc_b" -b \
                -o "target create $tmp_root/lldb-test" \
                -o 'image lookup -n cup_lldb_test_add_unique' \
                -o quit 2>&1 | tee "$tmp_root/lldb-reloc-b-output.txt"
            grep -F 'cup_lldb_test_add_unique' "$tmp_root/lldb-reloc-b-output.txt"

            mv "$reloc_b" "$reloc_c"
            [ ! -e "$reloc_b" ] || { echo 'LLDB relocation B root is still available' >&2; exit 1; }
            lldb_identity_probe "$reloc_c" C
            run_lldb_clean "$reloc_c" -b \
                -o "target create $tmp_root/lldb-test" \
                -o 'image lookup -n cup_lldb_test_add_unique' \
                -o quit 2>&1 | tee "$tmp_root/lldb-reloc-c-output.txt"
            grep -F 'cup_lldb_test_add_unique' "$tmp_root/lldb-reloc-c-output.txt"
            if [[ "$(info_value platform.host)" == linux-* ]] && info_bool features.lldb_server; then
                lldb_remote_debug_probe "$reloc_c" C
            fi
        else
            "$reloc_root/bin/lldb" --version
            "$reloc_root/bin/lldb" -b \
                -o "script import sys; print('python-reloc-ok', sys.version_info[0], sys.version_info[1])" \
                -o "target create $tmp_root/lldb-test" \
                -o "image lookup -n cup_lldb_test_add_unique" \
                -o quit 2>&1 | tee "$tmp_root/lldb-reloc-output.txt"
            grep -F "python-reloc-ok" "$tmp_root/lldb-reloc-output.txt"
            grep -F "cup_lldb_test_add_unique" "$tmp_root/lldb-reloc-output.txt"
        fi
        ;;
    clangd)
        rm -rf "$reloc_root"
        reloc_b="$tmp_root/relocated-clangd-b"
        reloc_c="$tmp_root/relocation clangd c with spaces"
        cp -RPp "$root" "$reloc_b"
        mv "$root" "$tmp_root/original-clangd-root-disabled"
        [ ! -e "$root" ] || { echo 'clangd relocation A root is still available' >&2; exit 1; }

        "$reloc_b/bin/clangd" --check="$project_dir/main.c" 2>&1 | tee "$tmp_root/clangd-reloc-b-output.txt"
        assert_output_contains "$tmp_root/clangd-reloc-b-output.txt" "All checks completed|Testing on source file"

        mv "$reloc_b" "$reloc_c"
        [ ! -e "$reloc_b" ] || { echo 'clangd relocation B root is still available' >&2; exit 1; }
        "$reloc_c/bin/clangd" --check="$project_dir/main.c" 2>&1 | tee "$tmp_root/clangd-reloc-c-output.txt"
        assert_output_contains "$tmp_root/clangd-reloc-c-output.txt" "All checks completed|Testing on source file"
        ;;
    clang-format)
        rm -rf "$reloc_root"
        reloc_b="$tmp_root/relocated-clang-format-b"
        reloc_c="$tmp_root/relocation clang-format c with spaces"
        cp -RPp "$root" "$reloc_b"
        mv "$root" "$tmp_root/original-clang-format-root-disabled"
        [ ! -e "$root" ] || { echo 'clang-format relocation A root is still available' >&2; exit 1; }
        "$reloc_b/bin/clang-format" "$tmp_root/format-test.c" | tee "$tmp_root/format-reloc-b-output.c"
        grep -F "int main(void)" "$tmp_root/format-reloc-b-output.c"
        mv "$reloc_b" "$reloc_c"
        [ ! -e "$reloc_b" ] || { echo 'clang-format relocation B root is still available' >&2; exit 1; }
        "$reloc_c/bin/clang-format" "$tmp_root/format-test.c" | tee "$tmp_root/format-reloc-c-output.c"
        grep -F "int main(void)" "$tmp_root/format-reloc-c-output.c"
        printf 'CLANG_FORMAT_RELOCATION_A_TO_B_TO_C=PASS\n'
        ;;
    clang-tidy)
        rm -rf "$reloc_root"
        reloc_b="$tmp_root/relocated-clang-tidy-b"
        reloc_c="$tmp_root/relocation clang-tidy c with spaces"
        cp -RPp "$root" "$reloc_b"
        mv "$root" "$tmp_root/original-clang-tidy-root-disabled"
        [ ! -e "$root" ] || { echo 'clang-tidy relocation A root is still available' >&2; exit 1; }
        llvm_helper_python_identity_probe "$reloc_b" B
        clang_tidy_helper_probe "$reloc_b" B
        "$reloc_b/bin/clang-tidy" "--checks=clang-analyzer-*" "$tmp_root/tidy-test.c" -- -std=c11
        "$reloc_b/bin/clang-apply-replacements" --version
        mv "$reloc_b" "$reloc_c"
        [ ! -e "$reloc_b" ] || { echo 'clang-tidy relocation B root is still available' >&2; exit 1; }
        llvm_helper_python_identity_probe "$reloc_c" C
        clang_tidy_helper_probe "$reloc_c" C
        "$reloc_c/bin/clang-tidy" "--checks=clang-analyzer-*" "$tmp_root/tidy-test.c" -- -std=c11
        "$reloc_c/bin/clang-apply-replacements" --version
        printf 'CLANG_TIDY_RELOCATION_A_TO_B_TO_C=PASS\n'
        ;;
esac
