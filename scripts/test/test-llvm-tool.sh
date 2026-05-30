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
cleanup() {
    rm -rf "$tmp_root"
}
trap cleanup EXIT

rm -rf dist/package-test
mkdir -p dist/package-test
tar -xJf "dist/$package_base.tar.xz" -C dist/package-test

root="dist/package-test/$package_base"
root="$(cd "$root" && pwd)"
export PATH="$root/bin:$PATH"

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

case "$LLVM_TOOL" in
    clang)
        require_executable "$root/bin/clang"
        require_executable "$root/bin/clang++"
        require_executable "$root/bin/ld.lld"

        "$root/bin/clang" --version
        "$root/bin/clang++" --version
        "$root/bin/ld.lld" --version

        resource_dir="$("$root/bin/clang" -print-resource-dir)"
        echo "clang resource dir: $resource_dir"
        test -d "$resource_dir"

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
        "$root/bin/clang" "${sdk_args[@]}" "$tmp_root/clang-test.c" -o "$tmp_root/clang-test"
        "$tmp_root/clang-test" | grep -F "hello clang 42"

        if [ "$(uname -s)" = "Darwin" ]; then
            echo "warning: skipping clang -fuse-ld=lld and LTO link tests on macOS"
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
        "$root/bin/clang++" "${sdk_args[@]}" "$tmp_root/clang-cpp-test.cpp" -o "$tmp_root/clang-cpp-test"
        "$tmp_root/clang-cpp-test" | grep -F "42"

        if info_bool features.asan || info_bool features.sanitizers; then
            cat > "$tmp_root/asan-test.c" <<'ASAN_C_EOF'
#include <stdlib.h>

int main(void) {
    int *value = (int *)malloc(sizeof(int));
    free(value);
    return *value;
}
ASAN_C_EOF
            if "$root/bin/clang" "${sdk_args[@]}" -g -O0 -fsanitize=address "$tmp_root/asan-test.c" -o "$tmp_root/asan-test"; then
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
            echo "warning: clang sanitizer runtime not enabled; skipping ASan test"
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
            echo "warning: skipping direct lld link test on macOS"
        else
            cc -B"$root/bin" -fuse-ld=lld "$tmp_root/lld-test.c" -o "$tmp_root/lld-test"
            "$tmp_root/lld-test" | grep -F "hello lld"
        fi
        ;;
    lldb)
        require_executable "$root/bin/lldb"

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

        "$root/bin/clangd" --version
        project_dir="$tmp_root/clangd-project"
        mkdir -p "$project_dir"
        cat > "$project_dir/main.c" <<'C_EOF'
#include <stdio.h>

int main(void) {
    printf("hello clangd\n");
    return 0;
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

        "$root/bin/clang-tidy" --version
        "$root/bin/clang-tidy" --list-checks "--checks=clang-analyzer-*" | tee "$tmp_root/tidy-checks.txt"
        grep -F "clang-analyzer-core" "$tmp_root/tidy-checks.txt"
        cat > "$tmp_root/tidy-test.c" <<'C_EOF'
int main(void) {
    return 0;
}
C_EOF
        "$root/bin/clang-tidy" "--checks=clang-analyzer-*" "$tmp_root/tidy-test.c" -- -std=c11
        ;;
    *)
        echo "unsupported LLVM tool: $LLVM_TOOL" >&2
        exit 2
        ;;
esac
