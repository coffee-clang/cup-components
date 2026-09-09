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

# lldb and lldb-dap are deliberate public CUP commands on every supported
# LLDB platform. lldb-server is additionally public on Linux/Windows, while
# lldb-argdumper remains a required private runtime helper for process launch.
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
grep -F '"$candidate/bin/lldb-server" platform --server' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB Linux remote qualification no longer uses packaged platform-server mode' >&2
    exit 1
}
grep -F 'platform select remote-linux' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB Linux remote qualification no longer selects remote-linux' >&2
    exit 1
}
grep -F 'platform connect connect://127.0.0.1:$port' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB Linux remote qualification no longer connects through the platform plugin' >&2
    exit 1
}
grep -F "target create '\$work/remote-test'" "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB platform remote qualification no longer starts from the local target fixture' >&2
    exit 1
}
grep -F 'settings set target.disable-aslr false' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB remote client no longer owns the container-compatible ASLR setting' >&2
    exit 1
}
grep -F 'packaged LLDB platform remote-debugging client timed out at relocation $label' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB platform remote client timeout no longer fails closed with evidence' >&2
    exit 1
}
if grep -F 'gdb-remote 127.0.0.1:$port' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null; then
    echo 'obsolete targetless gdb-remote orchestration remains in LLDB qualification' >&2
    exit 1
fi
grep -F 'lldb_dap_probe()' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB POSIX qualification no longer executes a real DAP protocol probe' >&2
    exit 1
}
grep -F 'platform select remote-windows' "$WINDOWS_TEST" >/dev/null || {
    echo 'LLDB Windows qualification no longer uses remote-windows platform mode' >&2
    exit 1
}
grep -F "'thread backtrace'" "$WINDOWS_TEST" >/dev/null || {
    echo 'LLDB Windows qualification lost canonical thread backtrace' >&2
    exit 1
}
if grep -F "'-o', 'backtrace'" "$WINDOWS_TEST" >/dev/null; then
    echo 'LLDB Windows qualification still contains invalid bare backtrace command' >&2
    exit 1
fi
grep -F 'function Invoke-LldbDapProbe' "$WINDOWS_TEST" >/dev/null || {
    echo 'LLDB Windows qualification no longer executes a real DAP protocol probe' >&2
    exit 1
}
grep -F "if ((Test-InfoBool 'features.process_launch') -and -not (Test-Path \"\$root\bin\lldb-argdumper.exe\")) {" "$WINDOWS_TEST" >/dev/null || {
    echo 'LLDB Windows process-launch capability gate has invalid PowerShell boolean grouping' >&2
    exit 1
}
grep -F "if (\$path -eq '.') {" "$WINDOWS_TEST" >/dev/null || {
    echo 'LLDB Windows Python qualification no longer permits the deliberate upstream current-directory entry' >&2
    exit 1
}
grep -F 'if (-not [IO.Path]::IsPathRooted($path)) {' "$WINDOWS_TEST" >/dev/null || {
    echo 'LLDB Windows Python qualification no longer rejects unexpected relative sys.path entries' >&2
    exit 1
}
grep -F 'print("lldb-file=" + str(lldb.__file__))' "$WINDOWS_TEST" >/dev/null || {
    echo 'LLDB Windows Python qualification no longer records the package-owned lldb module identity' >&2
    exit 1
}
grep -F 'LLDB Python module escaped the package at relocation ${Label}: $lldbFile' "$WINDOWS_TEST" >/dev/null || {
    echo 'LLDB Windows Python qualification no longer fails closed on an external lldb module' >&2
    exit 1
}
grep -F 'if [[ "$(info_value platform.host)" == linux-* || "$(info_value platform.host)" == macos-* ]]; then' "$ROOT/scripts/test/test-llvm-tool.sh" >/dev/null || {
    echo 'LLDB POSIX relocation no longer includes macOS previous-root isolation' >&2
    exit 1
}
if grep -F '[ -x "$PACKAGE_PREFIX/bin/lldb-dap" ] || die' "$SCRIPT" >/dev/null; then
    echo 'LLDB Linux seed duplicates lldb-dap public-entry enforcement instead of leaving it to metadata validation' >&2
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
