#!/usr/bin/env bash
set -euo pipefail

source dist/release.env

rm -rf dist/package-test
mkdir -p dist/package-test
tar -xJf "dist/$package_base.tar.xz" -C dist/package-test

root="dist/package-test/$package_base"

"$root/bin/gdb" --version
"$root/bin/gdb" --configuration
ldd "$root/bin/gdb" | tee /tmp/cup-gdb-ldd.txt

grep -F "config.python=true" "$root/info.txt"
grep -F "config.readline=system" "$root/info.txt"
grep -F "config.expat=true" "$root/info.txt"
grep -F "config.zlib=true" "$root/info.txt"
grep -F "config.lzma=true" "$root/info.txt"
grep -F "config.zstd=true" "$root/info.txt"
grep -F "config.debuginfod=true" "$root/info.txt"
grep -F "config.source_highlight=true" "$root/info.txt"
grep -F "config.xxhash=true" "$root/info.txt"
grep -F "config.babeltrace=true" "$root/info.txt"
grep -F "config.intel_pt=true" "$root/info.txt"

"$root/bin/gdb" -q -batch \
    -ex "python import sys, gdb; print(\"python-ok\", sys.version_info[0], sys.version_info[1])" | tee /tmp/cup-gdb-python-output.txt
grep -F "python-ok" /tmp/cup-gdb-python-output.txt

cat > /tmp/cup-gdb-test.c <<'C_EOF'
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

gcc -g -O0 /tmp/cup-gdb-test.c -o /tmp/cup-gdb-test
"$root/bin/gdb" -q -batch \
    -ex "file /tmp/cup-gdb-test" \
    -ex "break add" \
    -ex "set debuginfod enabled off" \
    -ex "run" \
    -ex "print a" \
    -ex "print b" \
    -ex "backtrace" | tee /tmp/cup-gdb-output.txt

grep -F '$1 = 20' /tmp/cup-gdb-output.txt
grep -F '$2 = 22' /tmp/cup-gdb-output.txt
