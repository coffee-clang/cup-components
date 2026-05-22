#!/usr/bin/env bash
set -euo pipefail

source dist/release.env

rm -rf dist/package-test
mkdir -p dist/package-test
tar -xJf "dist/$package_base.tar.xz" -C dist/package-test

root="dist/package-test/$package_base"
"$root/bin/valgrind" --version
"$root/bin/valgrind" --tool=memcheck --help >/tmp/cup-valgrind-help.txt
grep -A3 "available tools are:" /tmp/cup-valgrind-help.txt
grep -F "contents.mpi=true" "$root/info.txt"
find "$root" -type f -name "libmpiwrap-*" | grep .

cat > /tmp/cup-valgrind-leak.c <<'C_EOF'
#include <stdlib.h>

int main(void) {
    int *p = malloc(sizeof(int));
    *p = 42;
    return 0;
}
C_EOF

gcc -g -O0 /tmp/cup-valgrind-leak.c -o /tmp/cup-valgrind-leak
"$root/bin/valgrind" --leak-check=full /tmp/cup-valgrind-leak 2>&1 | tee /tmp/cup-valgrind-output.txt
grep "definitely lost: 4 bytes in 1 blocks" /tmp/cup-valgrind-output.txt

rm -rf /tmp/cup-valgrind-reloc
cp -a "$root" /tmp/cup-valgrind-reloc
/tmp/cup-valgrind-reloc/bin/valgrind --leak-check=full /tmp/cup-valgrind-leak 2>&1 | tee /tmp/cup-valgrind-reloc-output.txt
grep "definitely lost: 4 bytes in 1 blocks" /tmp/cup-valgrind-reloc-output.txt
