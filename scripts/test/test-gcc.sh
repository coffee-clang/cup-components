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

require_pe_file() {
    local file_path="$1"

    test -s "$file_path"
    file "$file_path" | grep -i "PE"
}

if [ "$HOST_PLATFORM" != "linux-x64" ]; then
    echo "unsupported host platform for this test script: $HOST_PLATFORM" >&2
    exit 2
fi

if [ "$TARGET_PLATFORM" = "linux-x64" ]; then
    export PATH="$root/bin:$PATH"

    "$root/bin/gcc" --version
    "$root/bin/g++" --version
    "$root/bin/as" --version
    "$root/bin/ld" --version
    "$root/bin/gcc" -print-libgcc-file-name
    "$root/bin/gcc" -print-prog-name=cc1

    cat > /tmp/cup-gcc-c-test.c <<'C_EOF'
#include <stdio.h>

int main(void) {
    printf("hello gcc c\n");
    return 0;
}
C_EOF
    "$root/bin/gcc" /tmp/cup-gcc-c-test.c -o /tmp/cup-gcc-c-test
    /tmp/cup-gcc-c-test | grep -F "hello gcc c"

    cat > /tmp/cup-gcc-cpp-test.cpp <<'CPP_EOF'
#include <iostream>
#include <vector>

int main() {
    std::vector<int> values = {20, 22};
    std::cout << (values[0] + values[1]) << "\n";
    return 0;
}
CPP_EOF
    "$root/bin/g++" /tmp/cup-gcc-cpp-test.cpp -o /tmp/cup-gcc-cpp-test
    /tmp/cup-gcc-cpp-test | grep -F "42"

    cat > /tmp/cup-gcc-pthread-test.c <<'PTHREAD_EOF'
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
    "$root/bin/gcc" /tmp/cup-gcc-pthread-test.c -o /tmp/cup-gcc-pthread-test -pthread
    /tmp/cup-gcc-pthread-test | grep -F "pthread 42"

    cat > /tmp/cup-gcc-lto-test.c <<'LTO_EOF'
static int add(int a, int b) {
    return a + b;
}

int main(void) {
    return add(20, 22) == 42 ? 0 : 1;
}
LTO_EOF
    "$root/bin/gcc" -flto /tmp/cup-gcc-lto-test.c -o /tmp/cup-gcc-lto-test
    /tmp/cup-gcc-lto-test
elif [ "$TARGET_PLATFORM" = "windows-x64" ]; then
    target_prefix="x86_64-w64-mingw32"

    "$root/bin/$target_prefix-gcc" --version
    "$root/bin/$target_prefix-g++" --version
    "$root/bin/$target_prefix-as" --version
    "$root/bin/$target_prefix-ld" --version

    cat > /tmp/cup-gcc-windows-c-test.c <<'C_EOF'
int main(void) {
    return 0;
}
C_EOF
    "$root/bin/$target_prefix-gcc" /tmp/cup-gcc-windows-c-test.c -o /tmp/cup-gcc-windows-c-test.exe
    require_pe_file /tmp/cup-gcc-windows-c-test.exe

    cat > /tmp/cup-gcc-windows-cpp-test.cpp <<'CPP_EOF'
#include <iostream>
#include <vector>

int main() {
    std::vector<int> values = {20, 22};
    std::cout << (values[0] + values[1]) << "\n";
    return 0;
}
CPP_EOF
    "$root/bin/$target_prefix-g++" /tmp/cup-gcc-windows-cpp-test.cpp -o /tmp/cup-gcc-windows-cpp-test.exe
    require_pe_file /tmp/cup-gcc-windows-cpp-test.exe

    cat > /tmp/cup-gcc-windows-pthread-test.c <<'PTHREAD_EOF'
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
    "$root/bin/$target_prefix-gcc" /tmp/cup-gcc-windows-pthread-test.c -o /tmp/cup-gcc-windows-pthread-test.exe -pthread
    require_pe_file /tmp/cup-gcc-windows-pthread-test.exe

    cat > /tmp/cup-gcc-windows-lto-test.c <<'LTO_EOF'
static int add(int a, int b) {
    return a + b;
}

int main(void) {
    return add(20, 22) == 42 ? 0 : 1;
}
LTO_EOF
    "$root/bin/$target_prefix-gcc" -flto /tmp/cup-gcc-windows-lto-test.c -o /tmp/cup-gcc-windows-lto-test.exe
    require_pe_file /tmp/cup-gcc-windows-lto-test.exe
else
    echo "unsupported target platform: $TARGET_PLATFORM" >&2
    exit 2
fi
