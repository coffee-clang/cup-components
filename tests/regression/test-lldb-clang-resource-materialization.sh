#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/build/build-llvm-tool.sh"

extract_function() {
    local name="$1"
    awk -v name="$name" '
      $0 ~ "^" name "\\(\\) \\{" {on=1}
      on {print}
      on && /^}/ {exit}
    ' "$SCRIPT"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
source "$ROOT/scripts/package/package-common.sh"
eval "$(extract_function clang_resource_dir)"
eval "$(extract_function materialize_lldb_clang_resources)"

VERSION=99.98.7
TOOL=lldb
PREFIX="$tmp/prefix"
mkdir -p "$tmp/build/lib/clang/99.98.7/include"
printf 'resource\n' > "$tmp/build/lib/clang/99.98.7/include/stddef.h"
materialize_lldb_clang_resources "$tmp/build"
grep -Fx resource "$PREFIX/lib/clang/99.98.7/include/stddef.h" >/dev/null

# A resource already installed by another LLVM version/layout is preserved.
printf 'installed\n' > "$PREFIX/lib/clang/99.98.7/include/stddef.h"
printf 'generated-new\n' > "$tmp/build/lib/clang/99.98.7/include/stddef.h"
materialize_lldb_clang_resources "$tmp/build"
grep -Fx installed "$PREFIX/lib/clang/99.98.7/include/stddef.h" >/dev/null

rm -rf "$PREFIX/lib/clang/99.98.7" "$tmp/build/lib/clang/99.98.7"
if (materialize_lldb_clang_resources "$tmp/build") >/dev/null 2>&1; then
    echo 'missing generated Clang resources were accepted' >&2
    exit 1
fi

echo LLDB_CLANG_RESOURCE_MATERIALIZATION=PASS
