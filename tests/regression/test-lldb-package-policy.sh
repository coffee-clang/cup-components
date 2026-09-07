#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/build/build-llvm-tool.sh"
WINDOWS_TEST="$ROOT/scripts/test/test-llvm-tool-windows.ps1"

for marker in \
    'lldb_python_package_dir="lib/python$lldb_python_version/dist-packages"' \
    'lldb_python_package_dir="lib/python$lldb_python_version/site-packages"' \
    'LLDB_PYTHON_RELATIVE_PATH=$lldb_python_package_dir' \
    'LLDB_PYTHON_EXE_RELATIVE_PATH=bin/python$lldb_python_version' \
    'LLDB_PACKAGED_PYTHON_RELATIVE="bin/python$lldb_python_version"' \
    'materialize_lldb_clang_resources' \
    'prepare_lldb_package_seed'; do
    grep -F "$marker" "$SCRIPT" >/dev/null || {
        echo "missing generic LLDB package policy: $marker" >&2
        exit 1
    }
done

# lldb is the only unconditional public CUP root. lldb-dap/lldb-server remain
# optional capability entries, while lldb-argdumper is a required private
# runtime helper for the deliberately supported process-launch capability.
grep -F 'llvm_copy_path_into_seed bin/lldb' "$SCRIPT" >/dev/null
grep -F 'llvm_copy_path_into_seed bin/lldb-dap' "$SCRIPT" >/dev/null
grep -F 'llvm_copy_path_into_seed bin/lldb-server' "$SCRIPT" >/dev/null
grep -F 'contents.clang_resources=$has_lldb_clang_resources' "$SCRIPT" >/dev/null || {
    echo 'LLDB metadata no longer derives Clang resources from the exact resource root' >&2
    exit 1
}
if grep -F "metadata_bool_for_dirs "\$PREFIX" 'lib/clang/*/include'" "$SCRIPT" >/dev/null; then
    echo 'LLDB metadata regressed to basename-only pathname matching' >&2
    exit 1
fi
grep -F 'lldb lldb-server lldb-dap lldb-argdumper' "$SCRIPT" >/dev/null || {
    echo 'LLDB pruning no longer preserves the lldb-argdumper runtime helper' >&2
    exit 1
}
grep -F 'LLDB process-launch runtime helper is missing: bin/lldb-argdumper' "$SCRIPT" >/dev/null || {
    echo 'LLDB packaging no longer requires lldb-argdumper before publishing process-launch capability' >&2
    exit 1
}
grep -F 'llvm_copy_path_into_seed bin/lldb-argdumper' "$SCRIPT" >/dev/null || {
    echo 'LLDB Linux package seed no longer carries lldb-argdumper' >&2
    exit 1
}
if grep -F 'rm -f "$python_dir/site-packages/lldb/lldb-argdumper"' "$SCRIPT" >/dev/null; then
    echo 'LLDB pruning regressed to removing the lldb-argdumper Python companion' >&2
    exit 1
fi
grep -F 'for python_packages_dir in site-packages dist-packages; do' "$SCRIPT" >/dev/null || {
    echo 'LLDB Linux seed no longer rebinds Python native modules across both package directory conventions' >&2
    exit 1
}
grep -F 'require_executable "$root/bin/lldb-argdumper"' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB POSIX qualification no longer requires the process-launch argdumper helper' >&2
    exit 1
}
grep -F "LLDB process-launch capability is missing lldb-argdumper.exe" "$WINDOWS_TEST" >/dev/null || {
    echo 'LLDB Windows qualification no longer requires the process-launch argdumper helper' >&2
    exit 1
}

grep -F 'lldb_remote_debug_probe()' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB product qualification no longer contains a real remote-debugging probe' >&2
    exit 1
}
grep -F 'lldb_remote_debug_probe "$reloc_c" C' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB remote-debugging qualification is no longer bound to relocation C' >&2
    exit 1
}
grep -F -- '--named-pipe "$fifo" 127.0.0.1:0' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB remote-debugging probe no longer starts lldb-server targetless' >&2
    exit 1
}
if grep -F -- '--named-pipe "$fifo" 127.0.0.1:0 -- "$work/remote-test"' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null; then
    echo 'LLDB remote-debugging probe regressed to server-side inferior launch' >&2
    exit 1
fi
grep -F 'settings set target.disable-aslr false' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB remote client no longer owns the container-compatible ASLR setting' >&2
    exit 1
}
grep -F "process launch --stop-at-entry -- '\$work/remote-test' '\$marker'" "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB remote probe no longer launches the inferior from the connected client' >&2
    exit 1
}
grep -F 'while [ "$attempt" -lt 600 ] && kill -0 "$lldb_client_pid" 2>/dev/null; do' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB remote client no longer has a bounded completion wait' >&2
    exit 1
}
grep -F 'packaged LLDB remote-debugging client timed out at relocation $label' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB remote client timeout no longer fails closed with evidence' >&2
    exit 1
}
grep -F 'while [ "$attempt" -lt 20 ] && kill -0 "$lldb_server_pid" 2>/dev/null; do' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB targetless remote server cleanup is no longer bounded after a successful session' >&2
    exit 1
}
if grep -F 'if ! wait "$lldb_server_pid"; then' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null; then
    echo 'LLDB remote probe regressed to an unbounded wait for targetless server exit' >&2
    exit 1
fi
grep -F "if ((Test-InfoBool 'features.process_launch') -and -not (Test-Path \"\$root\bin\lldb-argdumper.exe\")) {" "$WINDOWS_TEST" >/dev/null || {
    echo 'LLDB Windows process-launch capability gate has invalid PowerShell boolean grouping' >&2
    exit 1
}
grep -F 'if [[ "$(info_value platform.host)" == linux-* || "$(info_value platform.host)" == macos-* ]]; then' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB POSIX relocation no longer includes macOS previous-root isolation' >&2
    exit 1
}
if grep -F '[ -x "$PACKAGE_PREFIX/bin/lldb-dap" ] || die' "$SCRIPT" >/dev/null; then
    echo 'LLDB package seed incorrectly requires lldb-dap for every LLVM version' >&2
    exit 1
fi

# The Linux minimal seed is platform policy, not a release-specific exception.
grep -F 'if [ "$TOOL" != lldb ] || ! is_linux_platform "$HOST_PLATFORM"; then' "$SCRIPT" >/dev/null

# Windows must not embed the build-machine Python home. Its packaged runtime is
# version-locked, so avoid the limited-API linkage path that failed natively.
# POSIX deliberately uses a package-relative Python home.
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
grep -F -- '-DLLDB_ENABLE_PYTHON_LIMITED_API=OFF' "$SCRIPT" >/dev/null || {
    echo 'LLDB Windows no longer disables the failing limited Python API linkage path' >&2
    exit 1
}
grep -F 'info_file="$tmp_root/package-info.txt"' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB qualification no longer snapshots package metadata before relocation' >&2
    exit 1
}
grep -F 'grep -F "${key}=" "$info_file"' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB capability gates reverted to reading the moved package root' >&2
    exit 1
}
grep -F 'candidate="$(cd "$candidate" && pwd -P)"' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB identity probe no longer canonicalizes macOS /tmp filesystem identity' >&2
    exit 1
}
if grep -F 'feature_enabled ' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null; then
    echo 'LLDB product test references undefined feature_enabled instead of existing info_bool' >&2
    exit 1
fi

for marker in 'python-isolated=1' 'python-package-owned=1' 'relocation with spaces' 'original-package-root-disabled'; do
    grep -F "$marker" "$WINDOWS_TEST" >/dev/null || {
        echo "LLDB Windows product test lost relocation/Python isolation marker: $marker" >&2
        exit 1
    }
done

echo LLDB_PACKAGE_POLICY=PASS
