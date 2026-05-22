#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Usage:
  $0 <host_platform> <target_platform>

Examples:
  $0 linux-x64 linux-x64
  $0 linux-x64 windows-x64
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
tmpdir="$(mktemp -d /tmp/cup-gcc-test.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

require_executable() {
    local path="$1"

    if [ ! -x "$path" ]; then
        echo "missing executable: $path" >&2
        exit 1
    fi
}

require_pe_file() {
    local file_path="$1"

    test -s "$file_path"
    file "$file_path" | grep -i "PE"
}

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

log_optional_feature() {
    local name="$1"
    local key="$2"

    if feature_enabled "$key"; then
        echo "optional feature enabled: $name"
        return 0
    fi

    echo "optional feature not enabled: $name"
    return 1
}

if [ "$HOST_PLATFORM" != "linux-x64" ]; then
    echo "unsupported host platform for this test script: $HOST_PLATFORM" >&2
    exit 2
fi

if [ "$TARGET_PLATFORM" = "linux-x64" ]; then
    export PATH="$root/bin:$PATH"

    require_executable "$root/bin/gcc"
    require_executable "$root/bin/g++"
    require_executable "$root/bin/as"
    require_executable "$root/bin/ld"

    "$root/bin/gcc" --version
    "$root/bin/g++" --version
    "$root/bin/as" --version
    "$root/bin/ld" --version
    "$root/bin/gcc" -print-libgcc-file-name
    "$root/bin/gcc" -print-prog-name=cc1

    cat > "$tmpdir/c-test.c" <<'C_EOF'
#include <stdio.h>

int main(void) {
    printf("hello gcc c\n");
    return 0;
}
C_EOF
    "$root/bin/gcc" "$tmpdir/c-test.c" -o "$tmpdir/c-test"
    "$tmpdir/c-test" | grep -F "hello gcc c"

    cat > "$tmpdir/cpp-test.cpp" <<'CPP_EOF'
#include <iostream>
#include <vector>

int main() {
    std::vector<int> values = {20, 22};
    std::cout << (values[0] + values[1]) << "\n";
    return 0;
}
CPP_EOF
    "$root/bin/g++" "$tmpdir/cpp-test.cpp" -o "$tmpdir/cpp-test"
    "$tmpdir/cpp-test" | grep -F "42"

    cat > "$tmpdir/pthread-test.c" <<'PTHREAD_EOF'
#include <pthread.h>
#include <stdio.h>

static void *worker(void *arg) {
    return arg;
}

int main(void) {
    pthread_t thread;
    void *result = 0;

    if (pthread_create(&thread, 0, worker, (void *)42) != 0) {
        return 1;
    }

    if (pthread_join(thread, &result) != 0) {
        return 1;
    }

    printf("pthread %ld\n", (long)result);
    return result == (void *)42 ? 0 : 1;
}
PTHREAD_EOF
    "$root/bin/gcc" "$tmpdir/pthread-test.c" -o "$tmpdir/pthread-test" -pthread
    "$tmpdir/pthread-test" | grep -F "pthread 42"

    cat > "$tmpdir/lto-test.c" <<'LTO_EOF'
static int add(int a, int b) {
    return a + b;
}

int main(void) {
    return add(20, 22) == 42 ? 0 : 1;
}
LTO_EOF
    "$root/bin/gcc" -flto "$tmpdir/lto-test.c" -o "$tmpdir/lto-test"
    "$tmpdir/lto-test"

    if log_optional_feature "OpenMP" "contents.openmp"; then
        cat > "$tmpdir/openmp-test.c" <<'OMP_EOF'
#include <omp.h>
#include <stdio.h>

int main(void) {
    int n = 0;
#pragma omp parallel reduction(+:n)
    n += 1;
    printf("openmp %d\n", n);
    return n > 0 ? 0 : 1;
}
OMP_EOF
        "$root/bin/gcc" -fopenmp "$tmpdir/openmp-test.c" -o "$tmpdir/openmp-test"
        "$tmpdir/openmp-test" | grep -F "openmp"
    fi

    if log_optional_feature "sanitizers" "contents.sanitizers"; then
        cat > "$tmpdir/sanitizer-test.c" <<'SAN_EOF'
#include <stdio.h>

int main(void) {
    int x = 1;
    printf("sanitizer %d\n", x);
    return 0;
}
SAN_EOF
        "$root/bin/gcc" -fsanitize=undefined "$tmpdir/sanitizer-test.c" -o "$tmpdir/sanitizer-test"
        "$tmpdir/sanitizer-test" | grep -F "sanitizer 1"
    fi
elif [ "$TARGET_PLATFORM" = "windows-x64" ]; then
    target_prefix="x86_64-w64-mingw32"

    require_executable "$root/bin/$target_prefix-gcc"
    require_executable "$root/bin/$target_prefix-g++"
    require_executable "$root/bin/$target_prefix-as"
    require_executable "$root/bin/$target_prefix-ld"

    "$root/bin/$target_prefix-gcc" --version
    "$root/bin/$target_prefix-g++" --version
    "$root/bin/$target_prefix-as" --version
    "$root/bin/$target_prefix-ld" --version

    cat > "$tmpdir/windows-c-test.c" <<'C_EOF'
int main(void) {
    return 0;
}
C_EOF
    "$root/bin/$target_prefix-gcc" "$tmpdir/windows-c-test.c" -o "$tmpdir/windows-c-test.exe"
    require_pe_file "$tmpdir/windows-c-test.exe"

    cat > "$tmpdir/windows-cpp-test.cpp" <<'CPP_EOF'
#include <iostream>
#include <vector>

int main() {
    std::vector<int> values = {20, 22};
    std::cout << (values[0] + values[1]) << "\n";
    return 0;
}
CPP_EOF
    "$root/bin/$target_prefix-g++" "$tmpdir/windows-cpp-test.cpp" -o "$tmpdir/windows-cpp-test.exe"
    require_pe_file "$tmpdir/windows-cpp-test.exe"

    cat > "$tmpdir/windows-pthread-test.c" <<'PTHREAD_EOF'
#include <pthread.h>

static void *worker(void *arg) {
    return arg;
}

int main(void) {
    pthread_t thread;
    pthread_create(&thread, 0, worker, 0);
    pthread_join(thread, 0);
    return 0;
}
PTHREAD_EOF
    "$root/bin/$target_prefix-gcc" "$tmpdir/windows-pthread-test.c" -o "$tmpdir/windows-pthread-test.exe" -pthread
    require_pe_file "$tmpdir/windows-pthread-test.exe"

    cat > "$tmpdir/windows-lto-test.c" <<'LTO_EOF'
static int add(int a, int b) {
    return a + b;
}

int main(void) {
    return add(20, 22) == 42 ? 0 : 1;
}
LTO_EOF
    "$root/bin/$target_prefix-gcc" -flto "$tmpdir/windows-lto-test.c" -o "$tmpdir/windows-lto-test.exe"
    require_pe_file "$tmpdir/windows-lto-test.exe"

    if log_optional_feature "OpenMP" "contents.openmp"; then
        cat > "$tmpdir/windows-openmp-test.c" <<'OMP_EOF'
#include <omp.h>

int main(void) {
    int n = 0;
#pragma omp parallel reduction(+:n)
    n += 1;
    return n > 0 ? 0 : 1;
}
OMP_EOF
        "$root/bin/$target_prefix-gcc" -fopenmp "$tmpdir/windows-openmp-test.c" -o "$tmpdir/windows-openmp-test.exe"
        require_pe_file "$tmpdir/windows-openmp-test.exe"
    fi

    if log_optional_feature "sanitizers" "contents.sanitizers"; then
        cat > "$tmpdir/windows-sanitizer-test.c" <<'SAN_EOF'
int main(void) {
    int x = 1;
    return x == 1 ? 0 : 1;
}
SAN_EOF
        "$root/bin/$target_prefix-gcc" -fsanitize=undefined "$tmpdir/windows-sanitizer-test.c" -o "$tmpdir/windows-sanitizer-test.exe"
        require_pe_file "$tmpdir/windows-sanitizer-test.exe"
    fi
else
    echo "unsupported target platform: $TARGET_PLATFORM" >&2
    exit 2
fi
