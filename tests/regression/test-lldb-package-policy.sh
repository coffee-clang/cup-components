#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/build/build-llvm-tool.sh"

for marker in \
    'LLDB_PYTHON_RELATIVE_PATH=lib/python$lldb_python_version/site-packages' \
    'LLDB_PYTHON_EXE_RELATIVE_PATH=bin/python$lldb_python_version' \
    'LLDB_PACKAGED_PYTHON_RELATIVE="bin/python$lldb_python_version"' \
    'materialize_lldb_clang_resources' \
    'prepare_lldb_package_seed'; do
    grep -F "$marker" "$SCRIPT" >/dev/null || {
        echo "missing generic LLDB package policy: $marker" >&2
        exit 1
    }
done

# lldb is the only unconditional public root. Helper availability is upstream-
# version dependent and is represented by optional entries/features.
grep -F 'llvm_copy_path_into_seed bin/lldb' "$SCRIPT" >/dev/null
grep -F 'llvm_copy_path_into_seed bin/lldb-dap' "$SCRIPT" >/dev/null
grep -F 'llvm_copy_path_into_seed bin/lldb-server' "$SCRIPT" >/dev/null
if grep -F '[ -x "$PACKAGE_PREFIX/bin/lldb-dap" ] || die' "$SCRIPT" >/dev/null; then
    echo 'LLDB package seed incorrectly requires lldb-dap for every LLVM version' >&2
    exit 1
fi

# The Linux minimal seed is platform policy, not a release-specific exception.
grep -F 'if [ "$TOOL" != lldb ] || ! is_linux_platform "$HOST_PLATFORM"; then' "$SCRIPT" >/dev/null

echo LLDB_PACKAGE_POLICY=PASS
