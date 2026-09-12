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
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source dist/release.env

tmp_root="$(mktemp -d /tmp/cup-llvm-test.XXXXXX)"
lldb_server_pid=""
lldb_port_reader_pid=""
lldb_client_pid=""
FRAMED_PENDING=()
cleanup() {
    if [ -n "${lldb_port_reader_pid:-}" ]; then
        kill "$lldb_port_reader_pid" 2>/dev/null || true
        wait "$lldb_port_reader_pid" 2>/dev/null || true
    fi
    if [ -n "${lldb_client_pid:-}" ]; then
        kill "$lldb_client_pid" 2>/dev/null || true
        wait "$lldb_client_pid" 2>/dev/null || true
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
info_file="$tmp_root/package-info.txt"
cp -p "$root/info.txt" "$info_file"

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
    grep -F "${key}=" "$info_file" | tail -n 1 | sed 's/^[^=]*=//' || true
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

sha256_file() {
    local path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    else
        shasum -a 256 "$path" | awk '{print $1}'
    fi
}

clang_ubsan_probe() {
    local candidate="$1"
    local label="$2"
    local poison_dir="$3"
    local work="$tmp_root/clang-ubsan-$label"
    local clean_home="$tmp_root/clang-ubsan-home-$label"
    local sdk_args=()
    local status

    info_bool features.ubsan || {
        echo "required Clang UBSan capability is not declared" >&2
        return 1
    }
    rm -rf "$work"
    mkdir -p "$work"
    cat > "$work/ubsan.c" <<'C_UBSAN'
#include <limits.h>
int main(void) {
    volatile int value = INT_MAX;
    return value + 1;
}
C_UBSAN
    if [ "$(uname -s)" = Linux ]; then
        run_clang_driver_clean "$candidate" clang "$clean_home" "$poison_dir" \
            -g -O0 -fsanitize=undefined -fno-sanitize-recover=undefined \
            "$work/ubsan.c" -o "$work/ubsan-test"
    else
        run_macos_clang_clean "$candidate" clang "$clean_home" -g -O0 \
            -fsanitize=undefined -fno-sanitize-recover=undefined \
            "$work/ubsan.c" -o "$work/ubsan-test"
    fi
    set +e
    "$work/ubsan-test" > "$work/output.txt" 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || {
        echo "UBSan test unexpectedly succeeded at relocation $label" >&2
        cat "$work/output.txt" >&2
        return 1
    }
    assert_output_contains "$work/output.txt" 'runtime error:.*signed integer overflow|UndefinedBehaviorSanitizer'
    printf 'CLANG_UBSAN_%s=PASS\n' "$label"
}

clang_profile_runtime_probe() {
    local candidate="$1"
    local label="$2"
    local poison_dir="$3"
    local work="$tmp_root/clang-profile-$label"
    local clean_home="$tmp_root/clang-profile-home-$label"
    info_bool features.profile_runtime || {
        echo "required Clang profile runtime capability is not declared" >&2
        return 1
    }
    rm -rf "$work"
    mkdir -p "$work"
    cat > "$work/profile.c" <<'C_PROFILE'
int main(void) { return 0; }
C_PROFILE
    if [ "$(uname -s)" = Linux ]; then
        run_clang_driver_clean "$candidate" clang "$clean_home" "$poison_dir" \
            -O0 -fprofile-instr-generate "$work/profile.c" -o "$work/profile-test"
    else
        run_macos_clang_clean "$candidate" clang "$clean_home" -O0 -fprofile-instr-generate \
            "$work/profile.c" -o "$work/profile-test"
    fi
    LLVM_PROFILE_FILE="$work/cup-profile.profraw" "$work/profile-test"
    [ -s "$work/cup-profile.profraw" ] || {
        echo "Clang profile runtime did not write a non-empty profraw file at relocation $label" >&2
        return 1
    }
    printf 'CLANG_PROFILE_RUNTIME_%s=PASS\n' "$label"
}

clang_asan_probe() {
    local candidate="$1"
    local label="$2"
    local poison_dir="$3"
    local work="$tmp_root/clang-asan-$label"
    local clean_home="$tmp_root/clang-asan-home-$label"
    local status

    info_bool features.asan || {
        echo "required Clang ASan capability is not declared" >&2
        return 1
    }
    rm -rf "$work"
    mkdir -p "$work"
    cat > "$work/asan.c" <<'C_ASAN'
#include <stdlib.h>
int main(void) {
    int *value = (int *)malloc(sizeof(int));
    free(value);
    return *value;
}
C_ASAN
    if [ "$(uname -s)" = Linux ]; then
        run_clang_driver_clean "$candidate" clang "$clean_home" "$poison_dir" \
            -g -O0 -fsanitize=address "$work/asan.c" -o "$work/asan-test"
    else
        run_macos_clang_clean "$candidate" clang "$clean_home" -g -O0 -fsanitize=address \
            "$work/asan.c" -o "$work/asan-test"
    fi
    set +e
    ASAN_OPTIONS=abort_on_error=0:detect_leaks=0 "$work/asan-test" > "$work/output.txt" 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || {
        echo "ASan test unexpectedly succeeded at relocation $label" >&2
        cat "$work/output.txt" >&2
        return 1
    }
    assert_output_contains "$work/output.txt" 'AddressSanitizer|heap-use-after-free'
    printf 'CLANG_ASAN_%s=PASS\n' "$label"
}

clang_macos_package_libcxx_probe() {
    local candidate="$1"
    local label="$2"
    local work="$tmp_root/clang-macos-libcxx-$label"
    local clean_home="$tmp_root/clang-macos-libcxx-home-$label"
    local lib

    info_bool features.cxx_runtime || {
        echo "Clang macOS package does not declare its bundled C++ runtime" >&2
        return 1
    }
    for lib in libc++.a libunwind.a; do
        [ -f "$candidate/lib/$lib" ] || {
            echo "Clang macOS package-owned C++ runtime is missing $lib" >&2
            return 1
        }
    done
    [ -d "$candidate/include/c++/v1" ] || {
        echo "Clang macOS package-owned libc++ headers are missing" >&2
        return 1
    }

    rm -rf "$work"
    mkdir -p "$work" "$clean_home"
    cp "$tmp_root/clang-cpp-test.cpp" "$work/main.cpp"
    if ! run_macos_clang_clean "$candidate" clang++ "$clean_home" \
        -nostdinc++ -isystem "$candidate/include/c++/v1" -nostdlib++ \
        "$work/main.cpp" \
        "$candidate/lib/libc++.a" "$candidate/lib/libunwind.a" \
        -o "$work/libcxx-test" >"$work/link.log" 2>&1; then
        echo "Clang macOS package-owned libc++ link failed at relocation $label" >&2
        cat "$work/link.log" >&2
        return 1
    fi
    if ! "$work/libcxx-test" >"$work/output.txt" 2>&1; then
        echo "Clang macOS package-owned libc++ executable failed at relocation $label" >&2
        cat "$work/output.txt" >&2
        return 1
    fi
    if ! grep -Fx 42 "$work/output.txt" >/dev/null; then
        echo "Clang macOS package-owned libc++ produced unexpected output at relocation $label" >&2
        cat "$work/output.txt" >&2
        return 1
    fi
    if otool -L "$work/libcxx-test" | grep -E '(^|[[:space:]])(/usr/lib/|@rpath/)?libc\+\+\.1\.dylib' >/dev/null; then
        echo "Clang macOS bundled libc++ probe fell back to dynamic system libc++ at relocation $label" >&2
        otool -L "$work/libcxx-test" >&2
        return 1
    fi
    printf 'CLANG_MACOS_PACKAGE_LIBCXX_%s=PASS\n' "$label"
}

clang_tidy_replacements_probe() {
    local candidate="$1"
    local label="$2"
    local project="$tmp_root/tidy-replacements-$label"
    local source="$project/main.c"
    local fixes="$project/fixes.yaml"

    info_bool features.apply_replacements || {
        echo "clang-tidy package does not declare apply-replacements capability" >&2
        return 1
    }
    rm -rf "$project"
    mkdir -p "$project"
    cat > "$source" <<'C_TIDY_REPLACE'
int cup_tidy_value(int value) {
    if (value)
        return 42;
    return 0;
}
C_TIDY_REPLACE
    "$candidate/bin/clang-tidy" \
        -checks=-*,readability-braces-around-statements \
        "--export-fixes=$fixes" "$source" -- -std=c11 >/dev/null
    [ -s "$fixes" ] || {
        echo "clang-tidy did not export fixes at relocation $label" >&2
        return 1
    }
    grep -F 'Replacements:' "$fixes" >/dev/null || {
        echo "clang-tidy fixes file has no replacements at relocation $label" >&2
        cat "$fixes" >&2
        return 1
    }
    "$candidate/bin/clang-apply-replacements" "$project"
    grep -E 'if \(value\)[[:space:]]*\{' "$source" >/dev/null || {
        echo "clang-apply-replacements did not apply the exported braces fix at relocation $label" >&2
        cat "$source" >&2
        return 1
    }
    printf 'CLANG_TIDY_APPLY_REPLACEMENTS_%s=PASS\n' "$label"
}

lld_native_probe() {
    local candidate="$1"
    local label="$2"
    local host
    local work="$tmp_root/lld-native-$label"

    host="$(info_value platform.host)"
    rm -rf "$work"
    mkdir -p "$work"
    cat > "$work/main.c" <<'C_LLD_NATIVE'
#include <stdio.h>
int main(void) {
    puts("hello lld");
    return 0;
}
C_LLD_NATIVE

    case "$host" in
        linux-*)
            require_executable "$candidate/bin/ld.lld"
            "$candidate/bin/ld.lld" --version
            info_bool features.link_elf || { echo 'Linux LLD does not declare native ELF linking' >&2; return 1; }
            [ "$(info_value features.link_coff)" = false ] || { echo 'Linux LLD over-declares COFF linking' >&2; return 1; }
            [ "$(info_value features.link_wasm)" = false ] || { echo 'Linux LLD over-declares Wasm linking' >&2; return 1; }
            [ "$(info_value features.link_macho)" = false ] || { echo 'Linux LLD over-declares Mach-O linking' >&2; return 1; }
            cc -B"$candidate/bin" -fuse-ld=lld "$work/main.c" -o "$work/lld-test"
            ;;
        macos-*)
            require_executable "$candidate/bin/ld64.lld"
            "$candidate/bin/ld64.lld" --version
            info_bool features.link_macho || { echo 'macOS LLD does not declare native Mach-O linking' >&2; return 1; }
            [ "$(info_value features.link_elf)" = false ] || { echo 'macOS LLD over-declares ELF linking' >&2; return 1; }
            [ "$(info_value features.link_coff)" = false ] || { echo 'macOS LLD over-declares COFF linking' >&2; return 1; }
            [ "$(info_value features.link_wasm)" = false ] || { echo 'macOS LLD over-declares Wasm linking' >&2; return 1; }
            cc -fuse-ld="$candidate/bin/ld64.lld" "$work/main.c" -o "$work/lld-test"
            ;;
        *)
            echo "unsupported POSIX LLD host for native qualification: $host" >&2
            return 1
            ;;
    esac

    "$work/lld-test" | grep -Fx 'hello lld' >/dev/null
    printf 'LLD_NATIVE_%s=PASS\n' "$label"
}

framed_send() {
    local fd="$1"
    local body="$2"
    LC_ALL=C printf 'Content-Length: %d\r\n\r\n%s' "${#body}" "$body" >&"$fd"
}

framed_read() {
    local fd="$1"
    local timeout_seconds="$2"
    local line=""
    local length=""
    local body=""

    while IFS= read -r -t "$timeout_seconds" -u "$fd" line; do
        line="${line%$'\r'}"
        [ -n "$line" ] || break
        case "$line" in
            Content-Length:*)
                length="${line#Content-Length:}"
                length="${length//[[:space:]]/}"
                ;;
        esac
    done
    [[ "$length" =~ ^[0-9]+$ ]] && [ "$length" -gt 0 ] || return 1
    IFS= read -r -N "$length" -t "$timeout_seconds" -u "$fd" body || return 1
    FRAMED_MESSAGE="$body"
}

framed_wait() {
    local fd="$1"
    local log="$2"
    local pattern="$3"
    local timeout_seconds="${4:-120}"
    local deadline=$((SECONDS + timeout_seconds))
    local remaining
    local read_timeout
    local index
    local message

    # Protocol events and responses can be interleaved. Preserve messages that
    # belong to a later wait instead of consuming them irreversibly.
    for index in "${!FRAMED_PENDING[@]}"; do
        message="${FRAMED_PENDING[$index]}"
        if printf '%s\n' "$message" | grep -E "$pattern" >/dev/null; then
            FRAMED_MESSAGE="$message"
            unset 'FRAMED_PENDING[index]'
            FRAMED_PENDING=("${FRAMED_PENDING[@]}")
            return 0
        fi
    done

    while [ "$SECONDS" -lt "$deadline" ]; do
        remaining=$((deadline - SECONDS))
        read_timeout=2
        [ "$remaining" -ge "$read_timeout" ] || read_timeout="$remaining"
        [ "$read_timeout" -gt 0 ] || break

        if ! framed_read "$fd" "$read_timeout"; then
            continue
        fi
        printf '%s\n' "$FRAMED_MESSAGE" >> "$log"
        if printf '%s\n' "$FRAMED_MESSAGE" | grep -E "$pattern" >/dev/null; then
            return 0
        fi
        FRAMED_PENDING+=("$FRAMED_MESSAGE")
    done
    echo "timed out waiting for framed protocol message matching: $pattern" >&2
    cat "$log" >&2
    return 1
}

clangd_lsp_probe() {
    local candidate="$1"
    local label="$2"
    local project="$tmp_root/clangd-lsp-$label"
    local home="$tmp_root/clangd-lsp-home-$label"
    local log="$project/protocol.log"
    local err="$project/stderr.log"
    local main_uri main_text body
    local clangd_pid in_fd out_fd
    local i

    rm -rf "$project" "$home"
    mkdir -p "$project" "$home"
    cat > "$project/main.c" <<'C_CLANGD_LSP'
int cup_lsp_value(void) { return 42; }
int main(void) { return cup_lsp_value() == 42 ? 0 : 1; }
C_CLANGD_LSP
    cat > "$project/compile_commands.json" <<EOF_CLANGD_DB
[
  {"directory":"$project","command":"cc -std=c11 -c $project/main.c","file":"$project/main.c"}
]
EOF_CLANGD_DB
    main_uri="file://$project/main.c"
    main_text='int cup_lsp_value(void) { return 42; }\nint main(void) { return cup_lsp_value() == 42 ? 0 : 1; }\n'
    : > "$log"
    FRAMED_PENDING=()

    coproc CLANGD_LSP { env -i HOME="$home" PATH=/usr/bin:/bin LANG=C LC_ALL=C TZ=UTC \
        "$candidate/bin/clangd" 2>"$err"; }
    clangd_pid=$CLANGD_LSP_PID
    in_fd=${CLANGD_LSP[1]}
    out_fd=${CLANGD_LSP[0]}

    body="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"processId\":null,\"rootUri\":\"file://$project\",\"capabilities\":{}}}"
    framed_send "$in_fd" "$body"
    framed_wait "$out_fd" "$log" '"id"[[:space:]]*:[[:space:]]*1' 60
    printf '%s\n' "$FRAMED_MESSAGE" | grep -F '"capabilities"' >/dev/null || {
        echo "clangd initialize response did not expose server capabilities at relocation $label" >&2
        cat "$log" "$err" >&2
        return 1
    }
    printf '%s\n' "$FRAMED_MESSAGE" | grep -F '"error"' >/dev/null && {
        echo "clangd initialize returned an error at relocation $label" >&2
        cat "$log" "$err" >&2
        return 1
    }
    framed_send "$in_fd" '{"jsonrpc":"2.0","method":"initialized","params":{}}'
    body="{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"$main_uri\",\"languageId\":\"c\",\"version\":1,\"text\":\"$main_text\"}}}"
    framed_send "$in_fd" "$body"
    body="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"$main_uri\"}}}"
    framed_send "$in_fd" "$body"
    framed_wait "$out_fd" "$log" '"id"[[:space:]]*:[[:space:]]*2' 60
    printf '%s\n' "$FRAMED_MESSAGE" | grep -F 'cup_lsp_value' >/dev/null || {
        echo "clangd documentSymbol response missed cup_lsp_value at relocation $label" >&2
        cat "$log" "$err" >&2
        return 1
    }
    printf '%s\n' "$FRAMED_MESSAGE" | grep -F '"main"' >/dev/null || {
        echo "clangd documentSymbol response missed main at relocation $label" >&2
        cat "$log" "$err" >&2
        return 1
    }

    framed_send "$in_fd" '{"jsonrpc":"2.0","id":3,"method":"shutdown","params":null}'
    framed_wait "$out_fd" "$log" '"id"[[:space:]]*:[[:space:]]*3' 60
    framed_send "$in_fd" '{"jsonrpc":"2.0","method":"exit","params":null}'
    eval "exec ${in_fd}>&-" || true
    for i in $(seq 1 50); do
        kill -0 "$clangd_pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$clangd_pid" 2>/dev/null && kill "$clangd_pid" 2>/dev/null || true
    wait "$clangd_pid" 2>/dev/null || true
    if grep -E 'Failed to load compilation database|Failed to find compilation database|command clangd fallback' "$err" >/dev/null; then
        echo "clangd LSP did not consume its compilation database at relocation $label" >&2
        cat "$err" >&2
        return 1
    fi
    grep -F 'Loaded compilation database from' "$err" >/dev/null || {
        echo "clangd LSP did not report loading its compilation database at relocation $label" >&2
        cat "$err" >&2
        return 1
    }
    printf 'CLANGD_LSP_%s=PASS\n' "$label"
}

lldb_dap_probe() {
    local candidate="$1"
    local label="$2"
    local program="$3"
    local source="$4"
    local work="$tmp_root/lldb-dap-$label"
    local home="$tmp_root/lldb-dap-home-$label"
    local log="$work/protocol.log"
    local err="$work/stderr.log"
    local body line thread_id frame_id dap_pid in_fd out_fd i

    info_bool features.lldb_dap || return 0
    require_executable "$candidate/bin/lldb-dap"
    rm -rf "$work" "$home"
    mkdir -p "$work" "$home"
    line="$(grep -n 'cup_lldb_test_add_unique' "$source" | head -1 | cut -d: -f1)"
    [ -n "$line" ] || return 1
    : > "$log"
    FRAMED_PENDING=()

    coproc LLDB_DAP { env -i HOME="$home" PATH=/usr/bin:/bin LANG=C LC_ALL=C TZ=UTC \
        PYTHONDONTWRITEBYTECODE=1 "$candidate/bin/lldb-dap" 2>"$err"; }
    dap_pid=$LLDB_DAP_PID
    in_fd=${LLDB_DAP[1]}
    out_fd=${LLDB_DAP[0]}

    framed_send "$in_fd" '{"seq":1,"type":"request","command":"initialize","arguments":{"clientID":"cup-components","adapterID":"lldb","linesStartAt1":true,"columnsStartAt1":true}}'
    framed_wait "$out_fd" "$log" '"type"[[:space:]]*:[[:space:]]*"response".*"request_seq"[[:space:]]*:[[:space:]]*1.*"success"[[:space:]]*:[[:space:]]*true|"request_seq"[[:space:]]*:[[:space:]]*1.*"success"[[:space:]]*:[[:space:]]*true.*"type"[[:space:]]*:[[:space:]]*"response"' 60
    body="{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"program\":\"$program\",\"cwd\":\"$work\",\"stopOnEntry\":false,\"disableASLR\":false}}"
    framed_send "$in_fd" "$body"
    framed_wait "$out_fd" "$log" '"event"[[:space:]]*:[[:space:]]*"initialized"' 60
    body="{\"seq\":3,\"type\":\"request\",\"command\":\"setBreakpoints\",\"arguments\":{\"source\":{\"path\":\"$source\"},\"breakpoints\":[{\"line\":$line}]}}"
    framed_send "$in_fd" "$body"
    framed_wait "$out_fd" "$log" '"request_seq"[[:space:]]*:[[:space:]]*3.*"success"[[:space:]]*:[[:space:]]*true|"success"[[:space:]]*:[[:space:]]*true.*"request_seq"[[:space:]]*:[[:space:]]*3' 60
    framed_send "$in_fd" '{"seq":4,"type":"request","command":"configurationDone","arguments":{}}'
    # configurationDone may respond before or after the pending launch response.
    # The stopped-at-breakpoint oracle subsumes a successful configuration step,
    # so wait only for the launch response and do not make message ordering brittle.
    framed_wait "$out_fd" "$log" '"request_seq"[[:space:]]*:[[:space:]]*2.*"success"[[:space:]]*:[[:space:]]*true|"success"[[:space:]]*:[[:space:]]*true.*"request_seq"[[:space:]]*:[[:space:]]*2' 60
    framed_wait "$out_fd" "$log" '"event"[[:space:]]*:[[:space:]]*"stopped".*"reason"[[:space:]]*:[[:space:]]*"breakpoint"|"reason"[[:space:]]*:[[:space:]]*"breakpoint".*"event"[[:space:]]*:[[:space:]]*"stopped"' 60

    framed_send "$in_fd" '{"seq":5,"type":"request","command":"threads","arguments":{}}'
    framed_wait "$out_fd" "$log" '"request_seq"[[:space:]]*:[[:space:]]*5.*"success"[[:space:]]*:[[:space:]]*true|"success"[[:space:]]*:[[:space:]]*true.*"request_seq"[[:space:]]*:[[:space:]]*5' 60
    thread_id="$(printf '%s\n' "$FRAMED_MESSAGE" | grep -oE '"id"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')"
    [ -n "$thread_id" ] || { echo "lldb-dap returned no thread id" >&2; return 1; }
    body="{\"seq\":6,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":$thread_id,\"startFrame\":0,\"levels\":1}}"
    framed_send "$in_fd" "$body"
    framed_wait "$out_fd" "$log" '"request_seq"[[:space:]]*:[[:space:]]*6.*"success"[[:space:]]*:[[:space:]]*true|"success"[[:space:]]*:[[:space:]]*true.*"request_seq"[[:space:]]*:[[:space:]]*6' 60
    frame_id="$(printf '%s\n' "$FRAMED_MESSAGE" | grep -oE '"id"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')"
    [ -n "$frame_id" ] || { echo "lldb-dap returned no stack frame id" >&2; return 1; }
    body="{\"seq\":7,\"type\":\"request\",\"command\":\"evaluate\",\"arguments\":{\"expression\":\"a + b\",\"frameId\":$frame_id,\"context\":\"watch\"}}"
    framed_send "$in_fd" "$body"
    framed_wait "$out_fd" "$log" '"request_seq"[[:space:]]*:[[:space:]]*7.*"success"[[:space:]]*:[[:space:]]*true|"success"[[:space:]]*:[[:space:]]*true.*"request_seq"[[:space:]]*:[[:space:]]*7' 60
    printf '%s\n' "$FRAMED_MESSAGE" | grep -E '"result"[[:space:]]*:[[:space:]]*"[^\"]*42[^\"]*"' >/dev/null || {
        echo "lldb-dap evaluate did not return 42 at relocation $label" >&2
        cat "$log" "$err" >&2
        return 1
    }
    body="{\"seq\":8,\"type\":\"request\",\"command\":\"continue\",\"arguments\":{\"threadId\":$thread_id}}"
    framed_send "$in_fd" "$body"
    # A very short inferior can emit exited before the continue response.
    # Exit code 0 is the product oracle; do not require a transport ordering.
    framed_wait "$out_fd" "$log" '"event"[[:space:]]*:[[:space:]]*"exited".*"exitCode"[[:space:]]*:[[:space:]]*0|"exitCode"[[:space:]]*:[[:space:]]*0.*"event"[[:space:]]*:[[:space:]]*"exited"' 60
    framed_send "$in_fd" '{"seq":9,"type":"request","command":"disconnect","arguments":{"terminateDebuggee":false}}'
    framed_wait "$out_fd" "$log" '"request_seq"[[:space:]]*:[[:space:]]*9' 60 || true
    eval "exec ${in_fd}>&-" || true
    for i in $(seq 1 50); do
        kill -0 "$dap_pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$dap_pid" 2>/dev/null && kill "$dap_pid" 2>/dev/null || true
    wait "$dap_pid" 2>/dev/null || true
    printf 'LLDB_DAP_%s=PASS\n' "$label"
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

run_macos_clang_clean() {
    local candidate="$1"
    local driver="$2"
    local clean_home="$3"
    shift 3

    mkdir -p "$clean_home"
    env -i \
        HOME="$clean_home" \
        PATH=/usr/bin:/bin \
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

    if [ "$label" = C ]; then
        clang_asan_probe "$candidate" "$label" "$poison_dir"
        clang_ubsan_probe "$candidate" "$label" "$poison_dir"
        clang_profile_runtime_probe "$candidate" "$label" "$poison_dir"
    fi
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
        if [ "$expected_arch" = x86_64 ]; then
            case " $archs " in
                *' x86_64 '*) ;;
                *)
                    echo "missing x86_64 Mach-O slice for ${path#"$candidate"/}: $archs" >&2
                    exit 1
                    ;;
            esac
            for arch in $archs; do
                case "$arch" in
                    x86_64|x86_64h) ;;
                    *)
                        echo "unexpected Mach-O architecture for ${path#"$candidate"/}: $archs (expected x86_64 family)" >&2
                        exit 1
                        ;;
                esac
            done
        elif [ "$archs" != "$expected_arch" ]; then
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
    mkdir -p "$clean_home"

    "$candidate/bin/clang" --version
    resource_dir="$(require_package_owned_clang_resource_dir "$candidate")"
    echo "clang resource dir ($label): $resource_dir"

    run_macos_clang_clean "$candidate" clang "$clean_home" \
        "$tmp_root/clang-test.c" -o "$tmp_root/clang-macos-c-$label"
    "$tmp_root/clang-macos-c-$label" | grep -F "hello clang 42"

    run_macos_clang_clean "$candidate" clang++ "$clean_home" \
        "$tmp_root/clang-cpp-test.cpp" -o "$tmp_root/clang-macos-cpp-$label"
    "$tmp_root/clang-macos-cpp-$label" | grep -F "42"

    run_macos_clang_clean "$candidate" clang "$clean_home" -flto \
        -fuse-ld="$candidate/bin/ld64.lld" \
        "$tmp_root/clang-test.c" -o "$tmp_root/clang-macos-lto-$label"
    "$tmp_root/clang-macos-lto-$label" | grep -F "hello clang 42"

    if [ "$label" = C ]; then
        clang_macos_package_libcxx_probe "$candidate" "$label"
        clang_asan_probe "$candidate" "$label" ''
        clang_ubsan_probe "$candidate" "$label" ''
        clang_profile_runtime_probe "$candidate" "$label" ''
    fi
}

run_lldb_clean() {
    local candidate="$1"
    shift
    local clean_home="$tmp_root/clean-home"
    mkdir -p "$clean_home"
    env -i HOME="$clean_home" PATH=/usr/bin:/bin LANG=C LC_ALL=C TZ=UTC \
        PYTHONDONTWRITEBYTECODE=1 "$candidate/bin/lldb" "$@"
}


lldb_local_launch_probe() {
    local candidate="$1"
    local label="$2"
    local program="$3"
    local output="$tmp_root/lldb-launch-$label.txt"

    info_bool features.process_launch || return 0
    if run_lldb_clean "$candidate" -b \
        -o 'settings set target.disable-aslr false' \
        -o "target create $program" \
        -o 'breakpoint set --name cup_lldb_test_add_unique' \
        -o run \
        -o 'frame info' \
        -o 'frame variable a' \
        -o 'frame variable b' \
        -o continue \
        -o quit >"$output" 2>&1; then
        grep -F 'cup_lldb_test_add_unique' "$output"
        grep -F '(int) a = 20' "$output"
        grep -F '(int) b = 22' "$output"
        grep -E 'exited with status( =)? 0|Process [0-9]+ exited with status = 0' "$output" >/dev/null || {
            echo "LLDB local process did not reach a natural zero exit at relocation $label" >&2
            cat "$output" >&2
            return 1
        }
    else
        echo "LLDB process-launch capability could not be qualified at relocation $label; refusing a false PASS" >&2
        cat "$output" >&2
        return 1
    fi
    printf 'LLDB_LOCAL_LAUNCH_%s=PASS\n' "$label"
}

lldb_remote_debug_probe() {
    local candidate="$1"
    local label="$2"
    local work="$tmp_root/lldb-remote-$label"
    local remote_dir="$work/remote-root"
    local port_file="$work/platform.port"
    local server_out="$work/server.txt"
    local client_out="$work/client.txt"
    local port=""
    local attempt=0
    local client_status
    local server_status=0

    info_bool features.remote_debugging || {
        echo "LLDB remote-debugging capability is not declared at relocation $label" >&2
        return 1
    }
    require_executable "$candidate/bin/lldb-server"
    mkdir -p "$work" "$remote_dir" "$tmp_root/lldb-server-home-$label"
    cat > "$work/remote-test.c" <<'C_REMOTE_EOF'
volatile int cup_lldb_remote_value = 37;
__attribute__((noinline)) static void cup_lldb_remote_stop(int value) {
    __asm__ volatile("" : : "r"(value) : "memory");
}
int main(void) {
    int value = cup_lldb_remote_value + 5;
    cup_lldb_remote_stop(value);
    return value == 42 ? 0 : 2;
}
C_REMOTE_EOF
    cc -g -O0 "$work/remote-test.c" -o "$work/remote-test"

    rm -f "$port_file"
    (
        cd "$remote_dir"
        env -i HOME="$tmp_root/lldb-server-home-$label" PATH=/usr/bin:/bin \
            LANG=C LC_ALL=C TZ=UTC \
            "$candidate/bin/lldb-server" platform --server \
            --listen 127.0.0.1:0 --socket-file "$port_file"
    ) > "$server_out" 2>&1 &
    lldb_server_pid=$!

    while [ "$attempt" -lt 160 ]; do
        [ -s "$port_file" ] && break
        kill -0 "$lldb_server_pid" 2>/dev/null || break
        sleep 0.05
        attempt=$((attempt + 1))
    done
    [ -s "$port_file" ] || {
        echo "packaged lldb-server platform mode did not publish its port at relocation $label" >&2
        cat "$server_out" >&2
        return 1
    }
    port="$(LC_ALL=C tr -d '\000\r\n\t ' < "$port_file")"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
        echo "packaged lldb-server platform mode published an invalid port at relocation $label: $port" >&2
        cat "$server_out" >&2
        return 1
    }

    cat > "$work/client.cmd" <<EOF_REMOTE_CMD
platform select remote-linux
platform connect connect://127.0.0.1:$port
platform shell mkdir -p '$remote_dir'
platform settings -w '$remote_dir'
target create '$work/remote-test'
settings set target.disable-aslr false
breakpoint set -n cup_lldb_remote_stop
run
expression -- (int)(cup_lldb_remote_value + 5)
continue
platform shell rm -rf '$remote_dir/session-cleanup'
platform disconnect
quit
EOF_REMOTE_CMD

    env -i HOME="$tmp_root/clean-home" PATH=/usr/bin:/bin LANG=C LC_ALL=C TZ=UTC \
        PYTHONDONTWRITEBYTECODE=1 "$candidate/bin/lldb" -b -s "$work/client.cmd" \
        > "$client_out" 2>&1 &
    lldb_client_pid=$!
    attempt=0
    while [ "$attempt" -lt 750 ] && kill -0 "$lldb_client_pid" 2>/dev/null; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    if kill -0 "$lldb_client_pid" 2>/dev/null; then
        kill "$lldb_client_pid" 2>/dev/null || true
        sleep 0.1
        kill -0 "$lldb_client_pid" 2>/dev/null && kill -KILL "$lldb_client_pid" 2>/dev/null || true
        wait "$lldb_client_pid" 2>/dev/null || true
        lldb_client_pid=""
        echo "packaged LLDB platform remote-debugging client timed out at relocation $label" >&2
        cat "$server_out" "$client_out" >&2
        return 1
    fi
    set +e
    wait "$lldb_client_pid"
    client_status=$?
    set -e
    lldb_client_pid=""
    [ "$client_status" -eq 0 ] || {
        echo "packaged LLDB platform remote-debugging session failed at relocation $label" >&2
        cat "$server_out" "$client_out" >&2
        return 1
    }
    grep -E '\(int\).*42|=[[:space:]]*42' "$client_out" >/dev/null || {
        echo "packaged LLDB platform remote expression was not observed at relocation $label" >&2
        cat "$client_out" >&2
        return 1
    }
    grep -Ei 'exited with status[[:space:]]*=[[:space:]]*0|exited with status[[:space:]]+0' "$client_out" >/dev/null || {
        echo "packaged LLDB platform remote inferior did not exit naturally with status 0 at relocation $label" >&2
        cat "$client_out" >&2
        return 1
    }

    attempt=0
    while [ "$attempt" -lt 50 ] && kill -0 "$lldb_server_pid" 2>/dev/null; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    if kill -0 "$lldb_server_pid" 2>/dev/null; then
        kill "$lldb_server_pid" 2>/dev/null || true
        sleep 0.1
        kill -0 "$lldb_server_pid" 2>/dev/null && kill -KILL "$lldb_server_pid" 2>/dev/null || true
        wait "$lldb_server_pid" 2>/dev/null || true
    else
        set +e
        wait "$lldb_server_pid"
        server_status=$?
        set -e
        [ "$server_status" -eq 0 ] || {
            lldb_server_pid=""
            echo "packaged lldb-server platform process exited unsuccessfully at relocation $label" >&2
            cat "$server_out" "$client_out" >&2
            return 1
        }
    fi
    lldb_server_pid=""
    printf 'LLDB_PLATFORM_REMOTE_%s=PASS port=%s\n' "$label" "$port"
}

lldb_identity_probe() {
    local candidate="$1"
    local label="$2"

    candidate="$(cd "$candidate" && pwd -P)"
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

    if [ -d "$root/bin" ]; then
        for path in \
            "$root/bin"/libLTO.dll "$root/bin"/libLTO-[0-9]*.dll "$root/bin"/libLTO.[0-9]*.dll \
            "$root/bin"/libRemarks.dll "$root/bin"/libRemarks-[0-9]*.dll "$root/bin"/libRemarks.[0-9]*.dll \
            "$root/bin"/libclang.dll "$root/bin"/libclang-[0-9]*.dll "$root/bin"/libclang.[0-9]*.dll \
            "$root/bin"/libclang-cpp.dll "$root/bin"/libclang-cpp-[0-9]*.dll "$root/bin"/libclang-cpp.[0-9]*.dll \
            "$root/bin"/libClangdXPCLib.dll "$root/bin"/libClangdXPCLib-[0-9]*.dll "$root/bin"/libClangdXPCLib.[0-9]*.dll; do
            if [ -e "$path" ] || [ -L "$path" ]; then
                echo "LLVM shared development API leaked into package: ${path#"$root/"}" >&2
                exit 1
            fi
        done
    fi

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
                libc++.a|libunwind.a|libclang_rt.*)
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
        for required_feature in \
            features.c features.cpp features.resource_dir features.lld_integration \
            features.lto features.asan features.ubsan features.profile_runtime features.cxx_runtime; do
            info_bool "$required_feature" || {
                echo "required Clang capability is not declared: $required_feature" >&2
                exit 1
            }
        done
        require_executable "$root/bin/clang"
        require_executable "$root/bin/clang++"

        "$root/bin/clang" --version
        "$root/bin/clang++" --version
        if [ "$(uname -s)" = Darwin ]; then
            require_executable "$root/bin/ld64.lld"
            "$root/bin/ld64.lld" --version
        else
            require_executable "$root/bin/ld.lld"
            "$root/bin/ld.lld" --version
        fi

        resource_dir="$(require_package_owned_clang_resource_dir "$root")"
        echo "clang resource dir: $resource_dir"

        if [ "$(uname -s)" = "Linux" ]; then
            [ "$(info_value requires.system_development_environment)" = true ] || {
                echo 'Linux Clang is missing its native system development environment prerequisite metadata' >&2
                exit 1
            }
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
        if [ "$(uname -s)" = "Darwin" ]; then
            [ "$(info_value requires.apple_developer_tools)" = true ] || { echo 'macOS Clang is missing its Apple developer tools prerequisite metadata' >&2; exit 1; }
            [ "$(info_value requires.macos_sdk)" = true ] || { echo 'macOS Clang is missing its macOS SDK prerequisite metadata' >&2; exit 1; }
            [ "${#sdk_args[@]}" -gt 0 ] || { echo 'macOS Clang requires an active Apple macOS SDK' >&2; exit 1; }
        fi
        if [ "$(uname -s)" = "Linux" ]; then
            run_clang_driver_clean "$root" clang "$tmp_root/clang-home-A" "$clang_poison" \
                "$tmp_root/clang-test.c" -o "$tmp_root/clang-test"
        elif [ "$(uname -s)" = "Darwin" ]; then
            run_macos_clang_clean "$root" clang "$tmp_root/clang-macos-home-A" \
                "$tmp_root/clang-test.c" -o "$tmp_root/clang-test"
        else
            "$root/bin/clang" "${sdk_args[@]}" "$tmp_root/clang-test.c" -o "$tmp_root/clang-test"
        fi
        "$tmp_root/clang-test" | grep -F "hello clang 42"

        if [ "$(uname -s)" = "Darwin" ]; then
            run_macos_clang_clean "$root" clang "$tmp_root/clang-macos-home-A" \
                -fuse-ld="$root/bin/ld64.lld" \
                "$tmp_root/clang-test.c" -o "$tmp_root/clang-lld-test"
            "$tmp_root/clang-lld-test" | grep -F "hello clang 42"

            run_macos_clang_clean "$root" clang "$tmp_root/clang-macos-home-A" \
                -flto -fuse-ld="$root/bin/ld64.lld" \
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
#include <stdexcept>
#include <string>
#include <vector>

struct Base {
    virtual ~Base() = default;
};

struct Derived : Base {
    int value = 42;
};

int main() {
    std::vector<std::string> values = {"20", "22"};
    Base *base = new Derived();
    Derived *derived = dynamic_cast<Derived *>(base);
    if (derived == nullptr) return 1;

    int result = 0;
    try {
        throw std::runtime_error("cup-runtime");
    } catch (const std::exception &error) {
        if (std::string(error.what()) != "cup-runtime") return 2;
        result = std::stoi(values[0]) + std::stoi(values[1]);
    }
    if (derived->value != result) return 3;
    delete base;
    std::cout << result << "\n";
    return 0;
}
CPP_EOF
        mapfile -t sdk_args < <(macos_sdk_args)
        if [ "$(uname -s)" = "Linux" ]; then
            run_clang_driver_clean "$root" clang++ "$tmp_root/clang-home-A" "$clang_poison" \
                "$tmp_root/clang-cpp-test.cpp" -o "$tmp_root/clang-cpp-test"
        elif [ "$(uname -s)" = "Darwin" ]; then
            run_macos_clang_clean "$root" clang++ "$tmp_root/clang-macos-home-A" \
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
            if ldd "$tmp_root/clang-libcxx-test" 2>/dev/null | grep -E 'libc\+\+|libc\+\+abi' >/dev/null; then
                echo 'Linux packaged libc++ probe fell back to a dynamic libc++/libc++abi' >&2
                ldd "$tmp_root/clang-libcxx-test" >&2 || true
                exit 1
            fi
        elif [ "$(uname -s)" != "Darwin" ]; then
            "$root/bin/clang++" -stdlib=libc++ "$tmp_root/clang-cpp-test.cpp" -o "$tmp_root/clang-libcxx-test"
            "$tmp_root/clang-libcxx-test" | grep -F "42"
        fi

        if [ "$(uname -s)" = "Darwin" ]; then
            clang_macos_package_libcxx_probe "$root" A
        fi
        clang_asan_probe "$root" A "${clang_poison:-}"
        clang_ubsan_probe "$root" A "${clang_poison:-}"
        clang_profile_runtime_probe "$root" A "${clang_poison:-}"
        ;;
    lld)
        lld_native_probe "$root" A
        ;;
    lldb)
        require_executable "$root/bin/lldb"
        for required_feature in \
            features.python features.target_create features.breakpoints \
            features.symbol_lookup features.process_launch features.lldb_dap; do
            info_bool "$required_feature" || {
                echo "LLDB required capability is not declared: $required_feature" >&2
                exit 1
            }
        done

        case "$(info_value platform.host)" in
            linux-*)
                info_bool features.remote_debugging || {
                    echo 'Linux LLDB must declare package-owned remote debugging' >&2
                    exit 1
                }
                [ "$(info_value contents.lldb_server)" = true ] || {
                    echo 'Linux LLDB remote-debugging package does not declare lldb-server contents' >&2
                    exit 1
                }
                require_executable "$root/bin/lldb-server"
                ;;
            macos-*)
                [ "$(info_value features.remote_debugging)" = false ] || {
                    echo 'macOS LLDB must not declare package-owned remote debugging' >&2
                    exit 1
                }
                [ "$(info_value contents.lldb_server)" = false ] || {
                    echo 'macOS LLDB must not retain lldb-server contents' >&2
                    exit 1
                }
                [ "$(info_value contents.lldb_argdumper)" = true ] || {
                    echo 'macOS LLDB does not declare its private lldb-argdumper runtime helper' >&2
                    exit 1
                }
                [ ! -e "$root/bin/lldb-server" ] && [ ! -L "$root/bin/lldb-server" ] || {
                    echo 'macOS LLDB package unexpectedly contains lldb-server' >&2
                    exit 1
                }
                require_executable "$root/bin/lldb-argdumper"
                ;;
        esac

        if [[ "$(info_value platform.host)" != macos-* ]]; then
            [ "$(info_value contents.lldb_argdumper)" = false ] || {
                echo 'Linux LLDB unexpectedly declares lldb-argdumper contents' >&2
                exit 1
            }
            [ ! -e "$root/bin/lldb-argdumper" ] && [ ! -L "$root/bin/lldb-argdumper" ] || {
                echo 'Linux LLDB package unexpectedly contains lldb-argdumper' >&2
                exit 1
            }
        fi
        for forbidden_helper in analyze-cc analyze-c++ intercept-cc intercept-c++ ccc-analyzer c++-analyzer; do
            if [ -e "$root/libexec/$forbidden_helper" ] || [ -L "$root/libexec/$forbidden_helper" ]; then
                echo "LLDB package retained sibling analyzer helper: libexec/$forbidden_helper" >&2
                exit 1
            fi
        done

        if [ "$(info_value platform.host)" != windows-x64 ]; then
            lldb_python_entry="$(info_value config.python_executable)"
            [ -n "$lldb_python_entry" ] || { echo 'LLDB packaged Python executable is not declared' >&2; exit 1; }
            require_executable "$root/$lldb_python_entry"
        fi
        if [ "$(info_value platform.host)" != windows-x64 ]; then
            [ "$(info_value contents.clang_resources)" = true ] || { echo 'LLDB package-owned Clang resources not declared' >&2; exit 1; }
            lldb_identity_probe "$root" A
        fi
        if info_bool features.lldb_dap; then
            require_executable "$root/bin/lldb-dap"
        fi
        "$root/bin/lldb" --version
        "$root/bin/lldb" -b -o "script import sys; print('python-ok', sys.version_info[0], sys.version_info[1])" -o quit

        if [[ "$(info_value platform.host)" == macos-* ]]; then
            [ "$(info_value requires.system_debugserver)" = true ] || { echo 'macOS LLDB is missing its system debugserver prerequisite metadata' >&2; exit 1; }
        fi

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

        # Target/symbol creation is always qualified. If process launch is a
        # declared feature, the native runner must prove it; an environment
        # restriction is evidence-gap/failure, never a package PASS.
        "$root/bin/lldb" -b \
            -o "target create $tmp_root/lldb-test" \
            -o "breakpoint set --name cup_lldb_test_add_unique" \
            -o "image lookup -n cup_lldb_test_add_unique" \
            -o "quit" 2>&1 | tee "$tmp_root/lldb-output.txt"
        grep -F "Breakpoint" "$tmp_root/lldb-output.txt"
        grep -F "cup_lldb_test_add_unique" "$tmp_root/lldb-output.txt"

        lldb_local_launch_probe "$root" A "$tmp_root/lldb-test"
        if info_bool features.lldb_dap; then
            lldb_dap_probe "$root" A "$tmp_root/lldb-test" "$tmp_root/lldb-test.c"
        fi
        ;;
    clangd)
        require_executable "$root/bin/clangd"
        info_bool contents.clang_resources || { echo "clangd package does not declare package-owned Clang resources" >&2; exit 1; }
        info_bool features.resource_dir || { echo "clangd package does not declare resource-dir capability" >&2; exit 1; }
        info_bool features.check_compile_commands || { echo "clangd package does not declare compile-command consumption" >&2; exit 1; }
        info_bool features.lsp || { echo "clangd package does not declare its LSP capability" >&2; exit 1; }
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
        clangd_lsp_probe "$root" A
        ;;
    clang-format)
        require_executable "$root/bin/clang-format"
        for required_feature in features.format_file features.style_config features.dry_run_werror; do
            info_bool "$required_feature" || {
                echo "required clang-format capability is not declared: $required_feature" >&2
                exit 1
            }
        done

        "$root/bin/clang-format" --version

        if info_bool features.git_clang_format || [ -e "$root/bin/git-clang-format" ] || [ -L "$root/bin/git-clang-format" ]; then
            echo 'clang-format package retained git-clang-format despite the standalone formatter contract' >&2
            exit 1
        fi
        [ ! -e "$root/lib/clang" ] && [ ! -L "$root/lib/clang" ] || {
            echo 'clang-format package retained unused Clang resource headers' >&2
            exit 1
        }
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
        for required_feature in \
            features.list_checks features.analyze_c features.clang_analyzer \
            features.apply_replacements features.run_clang_tidy features.clang_tidy_diff; do
            info_bool "$required_feature" || {
                echo "required clang-tidy capability is not declared: $required_feature" >&2
                exit 1
            }
        done
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
        clang_tidy_replacements_probe "$root" A
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
unset PYTHONHOME PYTHONPATH || true
case "$LLVM_TOOL" in
    clang)
        mapfile -t sdk_args < <(macos_sdk_args)
        if [ "$(uname -s)" = "Linux" ]; then
            # A must disappear before B, and B before C. C contains real spaces.
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
            cp -RPp "$root" "$reloc_root"
            export PATH="$reloc_root/bin:$host_path"
            "$reloc_root/bin/clang" -flto -fuse-ld=lld "$tmp_root/clang-test.c" \
                -o "$tmp_root/clang-relocated-test"
            "$tmp_root/clang-relocated-test" | grep -F "hello clang 42"
        fi
        ;;
    lld)
        reloc_b="$tmp_root/relocated-lld-b"
        reloc_c="$tmp_root/relocation lld c with spaces"
        cp -RPp "$root" "$reloc_b"
        mv "$root" "$tmp_root/original-lld-root-disabled"
        [ ! -e "$root" ] || { echo 'LLD relocation A root is still available' >&2; exit 1; }
        "$reloc_b/bin/ld.lld" --version
        mv "$reloc_b" "$reloc_c"
        [ ! -e "$reloc_b" ] || { echo 'LLD relocation B root is still available' >&2; exit 1; }
        lld_native_probe "$reloc_c" C
        printf 'LLD_RELOCATION_A_TO_B_TO_C=PASS\n'
        ;;
    lldb)
        if [[ "$(info_value platform.host)" == linux-* || "$(info_value platform.host)" == macos-* ]]; then
            # LLDB carries package-owned Python/resource state on POSIX hosts. A
            # must disappear before B, and B before C, so absolute fallbacks
            # cannot satisfy the identity checks. C contains real spaces.
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
            lldb_local_launch_probe "$reloc_c" C "$tmp_root/lldb-test"
            if [[ "$(info_value platform.host)" == linux-* ]] && info_bool features.remote_debugging; then
                lldb_remote_debug_probe "$reloc_c" C
            fi
            if info_bool features.lldb_dap; then
                lldb_dap_probe "$reloc_c" C "$tmp_root/lldb-test" "$tmp_root/lldb-test.c"
            fi
        else
            cp -RPp "$root" "$reloc_root"
            export PATH="$reloc_root/bin:$host_path"
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
        clangd_lsp_probe "$reloc_c" C
        ;;
    clang-format)
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
        clang_tidy_replacements_probe "$reloc_c" C
        printf 'CLANG_TIDY_RELOCATION_A_TO_B_TO_C=PASS\n'
        ;;
esac
