#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Usage:
  $0 <llvm-tool>

Examples:
  $0 clang
  $0 clangd
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
export PATH="$root/bin:$PATH"

require_executable() {
    local path="$1"

    if [ ! -x "$path" ]; then
        echo "missing executable: $path" >&2
        exit 1
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

case "$LLVM_TOOL" in
    clang)
        require_executable "$root/bin/clang"
        require_executable "$root/bin/clang++"
        require_executable "$root/bin/ld.lld"

        "$root/bin/clang" --version
        "$root/bin/clang++" --version
        "$root/bin/ld.lld" --version

        resource_dir="$($root/bin/clang -print-resource-dir)"
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
        "$root/bin/clang" "$tmp_root/clang-test.c" -o "$tmp_root/clang-test"
        "$tmp_root/clang-test" | grep -F "hello clang 42"

        "$root/bin/clang" -fuse-ld=lld "$tmp_root/clang-test.c" -o "$tmp_root/clang-lld-test"
        "$tmp_root/clang-lld-test" | grep -F "hello clang 42"

        "$root/bin/clang" -flto -fuse-ld=lld "$tmp_root/clang-test.c" -o "$tmp_root/clang-lto-test"
        "$tmp_root/clang-lto-test" | grep -F "hello clang 42"

        cat > "$tmp_root/clang-cpp-test.cpp" <<'CPP_EOF'
#include <iostream>
#include <vector>

int main() {
    std::vector<int> values = {20, 22};
    std::cout << (values[0] + values[1]) << "\n";
    return 0;
}
CPP_EOF
        "$root/bin/clang++" "$tmp_root/clang-cpp-test.cpp" -o "$tmp_root/clang-cpp-test"
        "$tmp_root/clang-cpp-test" | grep -F "42"
        ;;
    lld)
        require_executable "$root/bin/ld.lld"

        # lld is a generic driver and may exit with a diagnostic when invoked directly.
        # Test the concrete frontends instead.
        "$root/bin/ld.lld" --version

        if [ -x "$root/bin/lld-link" ]; then
            "$root/bin/lld-link" --version
        fi

        if [ -x "$root/bin/wasm-ld" ]; then
            "$root/bin/wasm-ld" --version
        fi

        cat > "$tmp_root/lld-test.c" <<'C_EOF'
#include <stdio.h>

int main(void) {
    printf("hello lld\n");
    return 0;
}
C_EOF
        cc -B"$root/bin" -fuse-ld=lld "$tmp_root/lld-test.c" -o "$tmp_root/lld-test"
        "$tmp_root/lld-test" | grep -F "hello lld"
        ;;
    lldb)
        require_executable "$root/bin/lldb"

        "$root/bin/lldb" --version
        "$root/bin/lldb" -b -o "script import sys; print('python-ok', sys.version_info[0], sys.version_info[1])" -o quit

        cat > "$tmp_root/lldb-test.c" <<'C_EOF'
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
        cc -g -O0 "$tmp_root/lldb-test.c" -o "$tmp_root/lldb-test"
        "$root/bin/lldb" -b \
            -o "target create $tmp_root/lldb-test" \
            -o "breakpoint set --name add" \
            -o "run" \
            -o "frame variable a" \
            -o "frame variable b" \
            -o "bt" \
            -o "quit" 2>&1 | tee "$tmp_root/lldb-output.txt"
        grep -F "(int) a = 20" "$tmp_root/lldb-output.txt"
        grep -F "(int) b = 22" "$tmp_root/lldb-output.txt"
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
        ;;
    clang-tidy)
        require_executable "$root/bin/clang-tidy"

        "$root/bin/clang-tidy" --version
        "$root/bin/clang-tidy" --list-checks -checks=clang-analyzer-* | tee "$tmp_root/tidy-checks.txt"
        grep -F "clang-analyzer-core" "$tmp_root/tidy-checks.txt"
        cat > "$tmp_root/tidy-test.c" <<'C_EOF'
int main(void) {
    return 0;
}
C_EOF
        "$root/bin/clang-tidy" "$tmp_root/tidy-test.c" -- -std=c11
        ;;
    *)
        echo "unsupported LLVM tool: $LLVM_TOOL" >&2
        exit 2
        ;;
esac
