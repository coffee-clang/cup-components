#!/usr/bin/env bash
set -euo pipefail

source dist/release.env

tmp_root="$(mktemp -d /tmp/cup-leaks-test.XXXXXX)"
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

rm -rf dist/package-test
mkdir -p dist/package-test
tar -xJf "dist/$package_base.tar.xz" -C dist/package-test

root="dist/package-test/$package_base"
cat "$root/info.txt"

if [ ! -x "$root/bin/leaks" ]; then
    echo "missing leaks wrapper: $root/bin/leaks" >&2
    exit 1
fi

cat > "$tmp_root/leak-test.c" <<'C_EOF'
#include <stdlib.h>

int main(void) {
    void *p = malloc(64);
    p = 0;
    return 0;
}
C_EOF

cc -g -O0 "$tmp_root/leak-test.c" -o "$tmp_root/leak-test"

set +e
"$root/bin/leaks" -quiet -atExit -- "$tmp_root/leak-test" > "$tmp_root/leaks-output.txt" 2>&1
status="$?"
set -e

cat "$tmp_root/leaks-output.txt"

# leaks exits 1 when leaks are found, which is the expected result for this test.
if [ "$status" -ne 1 ]; then
    echo "expected leaks to report a leak with exit code 1, got $status" >&2
    exit 1
fi

grep -E "leak|leaks|total leaked bytes" "$tmp_root/leaks-output.txt" >/dev/null

echo "OK: leaks wrapper package test completed"
