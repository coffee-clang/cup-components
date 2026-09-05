#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/build/build-llvm-tool.sh"
WINDOWS_TEST="$ROOT/scripts/test/test-llvm-tool-windows.ps1"

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

# Windows must not embed the build-machine Python home. POSIX deliberately uses
# a package-relative Python home; the limited-API OFF flag is left to upstream's
# embedded-home policy rather than redundantly forced by this producer.
grep -F -- '-DLLDB_EMBED_PYTHON_HOME=OFF' "$SCRIPT" >/dev/null || {
    echo 'LLDB Windows lost explicit build-Python-home isolation' >&2
    exit 1
}
grep -F -- '-DLLDB_EMBED_PYTHON_HOME=ON' "$SCRIPT" >/dev/null || {
    echo 'LLDB POSIX lost package-relative embedded Python policy' >&2
    exit 1
}
grep -F -- '-DLLDB_PYTHON_HOME=..' "$SCRIPT" >/dev/null || {
    echo 'LLDB POSIX lost relative Python home' >&2
    exit 1
}
if grep -F -- '-DLLDB_ENABLE_PYTHON_LIMITED_API=OFF' "$SCRIPT" >/dev/null; then
    echo 'LLDB builder redundantly forces the limited Python API policy' >&2
    exit 1
fi
for marker in 'python-isolated=1' 'python-package-owned=1' 'relocation with spaces' 'original-package-root-disabled'; do
    grep -F "$marker" "$WINDOWS_TEST" >/dev/null || {
        echo "LLDB Windows product test lost relocation/Python isolation marker: $marker" >&2
        exit 1
    }
done

echo LLDB_PACKAGE_POLICY=PASS
