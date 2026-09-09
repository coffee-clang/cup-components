#!/usr/bin/env bash
set -euo pipefail
ROOT="${CUP_LLVM_CAPABILITY_POLICY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BUILD="$ROOT/scripts/build/build-llvm-tool.sh"
POSIX="$ROOT/scripts/test/test-llvm-tool.sh"
WINDOWS="$ROOT/scripts/test/test-llvm-tool-windows.ps1"
REPORT_POSIX="$ROOT/scripts/test/package-capabilities.sh"
REPORT_WINDOWS="$ROOT/scripts/test/package-capabilities-windows.ps1"
failures=0

need() {
    local file="$1" text="$2" message="$3"
    if ! grep -F -- "$text" "$file" >/dev/null 2>&1; then
        echo "LLVM capability-scope policy: $message" >&2
        failures=$((failures + 1))
    fi
}
reject() {
    local file="$1" text="$2" message="$3"
    if grep -F -- "$text" "$file" >/dev/null 2>&1; then
        echo "LLVM capability-scope policy: $message" >&2
        failures=$((failures + 1))
    fi
}

# Clang owns its deliberately built runtime capabilities, not arbitrary llvm-* feature promises.
need "$BUILD" 'features.cxx_runtime_default=$cxx_runtime_default' 'C++ default metadata is not owned by explicit build state'
need "$BUILD" 'CLANG_CXX_RUNTIME_DEFAULT=true' 'Windows packaged libc++ default is not owned by the driver-config writer'
reject "$BUILD" 'features.llvm_ar=' 'llvm-ar presence is still promoted to a Clang feature'
reject "$BUILD" 'features.llvm_ranlib=' 'llvm-ranlib presence is still promoted to a Clang feature'
reject "$BUILD" 'features.llvm_objdump=' 'llvm-objdump presence is still promoted to a Clang feature'
for stale_target_feature in \
    features.target_x86 features.target_aarch64 \
    features.target_linux_x64 features.target_linux_arm64 \
    features.target_windows_x64 features.target_macos_x64 features.target_macos_arm64; do
    reject "$BUILD" "$stale_target_feature=" \
        "Clang target/backend identity is still duplicated as behavioral feature metadata: $stale_target_feature"
done
need "$BUILD" 'config.llvm_targets=$LLVM_TARGETS' 'LLVM backend selection is no longer recorded as configuration metadata'
reject "$POSIX" 'clang_archive_tools_probe()' 'Clang still carries the over-scoped archive-tool qualification owner'
reject "$WINDOWS" 'function Invoke-ClangArchiveToolsProbe' 'Windows Clang still carries the over-scoped archive-tool qualification owner'
reject "$BUILD" 'entry.lld "$PREFIX" ld.lld' 'Clang still promotes its integration linker payload to a separate public entry'
for marker in 'clang_ubsan_probe()' 'clang_profile_runtime_probe()' 'clang_asan_probe()' 'clang_macos_package_libcxx_probe()'; do
    need "$POSIX" "$marker" "missing deliberate Clang runtime oracle: $marker"
done
need "$POSIX" 'clang_ubsan_probe "$root" A' 'UBSan is not exercised at original root'
need "$POSIX" 'clang_profile_runtime_probe "$root" A' 'profile runtime is not exercised at original root'
need "$POSIX" 'clang_ubsan_probe "$candidate" "$label"' 'UBSan is not exercised after relocation'
need "$POSIX" 'clang_profile_runtime_probe "$candidate" "$label"' 'profile runtime is not exercised after relocation'
need "$BUILD" 'requires.macos_sdk=true' 'macOS Clang SDK prerequisite is not explicit'

# Standalone LLD promises only the native link format; extra upstream frontends are inventory.
need "$BUILD" 'lld_link_elf="$has_lld"' 'Linux native ELF capability ownership is missing'
need "$BUILD" 'lld_link_coff="$has_lld_link"' 'Windows native COFF capability ownership is missing'
need "$BUILD" 'lld_link_macho="$has_ld64_lld"' 'macOS native Mach-O capability ownership is missing'
need "$BUILD" 'features.link_wasm=false' 'LLD incorrectly promotes WebAssembly linking into the current CUP target matrix'
need "$POSIX" 'lld_native_probe()' 'POSIX LLD has no native-format behavioral owner'
need "$WINDOWS" 'function Invoke-LldNativeProbe' 'Windows LLD has no native COFF behavioral owner'
reject "$POSIX" 'lld_cross_format_probe()' 'cross-format LLD qualification is still present'
reject "$WINDOWS" 'Invoke-LldCrossFormatProbe' 'Windows cross-format LLD qualification is still present'
[ ! -e "$ROOT/tests/fixtures/lld" ] || { echo 'LLVM capability-scope policy: LLD cross-format fixture directory still exists' >&2; failures=$((failures + 1)); }

# clang-tidy helper capabilities remain deliberate and must be exercised behaviorally.
need "$POSIX" 'clang_tidy_replacements_probe()' 'clang-tidy has no replacement oracle'
need "$POSIX" '--export-fixes=' 'clang-tidy replacement oracle does not export real fixes'
need "$POSIX" 'clang_tidy_replacements_probe "$root" A' 'clang-apply-replacements is not exercised at original root'
need "$POSIX" 'clang_tidy_replacements_probe "$reloc_c" C' 'clang-apply-replacements is not exercised after relocation'
need "$WINDOWS" 'function Invoke-ClangTidyReplacementsProbe' 'Windows clang-tidy has no replacement oracle'

# clangd must be tested as a real language server without promoting background indexing to CUP scope.
reject "$BUILD" 'features.background_index=' 'clangd background indexing is still promoted to a CUP feature'
reject "$BUILD" 'features.indexer=' 'optional clangd-indexer payload is still promoted to a CUP feature'
reject "$BUILD" 'entry.clangd_indexer' 'optional clangd-indexer payload is still promoted to a public entry'
need "$BUILD" 'contents.clangd_indexer=$has_clangd_indexer' 'optional clangd-indexer inventory is not recorded as contents'
need "$POSIX" 'clangd_lsp_probe()' 'POSIX clangd has no real LSP oracle'
need "$POSIX" 'textDocument/documentSymbol' 'POSIX clangd LSP oracle does not issue a semantic document request'
need "$POSIX" 'clangd_lsp_probe "$root" A' 'clangd LSP oracle is not run at original root'
need "$POSIX" 'clangd_lsp_probe "$reloc_c" C' 'clangd LSP oracle is not repeated after relocation'
need "$WINDOWS" 'function Invoke-ClangdLspProbe' 'Windows clangd has no real LSP oracle'
reject "$POSIX" '.cache/clangd/index' 'POSIX clangd still requires background-index cache internals'
reject "$WINDOWS" 'background-index entries' 'Windows clangd still requires background-index cache internals'

# LLDB retains deliberate process-control/DAP/remote responsibilities without
# promoting helper presence or non-equivalent platform probes into capabilities.
need "$POSIX" '"$candidate/bin/lldb-server" platform --server' 'Linux LLDB does not use packaged platform-server mode'
need "$POSIX" 'platform select remote-linux' 'Linux LLDB does not select remote-linux'
reject "$POSIX" 'gdb-remote 127.0.0.1:$port' 'obsolete direct targetless gdb-remote orchestration is still present'
need "$POSIX" 'lldb_dap_probe()' 'POSIX LLDB DAP claim has no protocol oracle'
need "$POSIX" '\"disableASLR\":false' 'POSIX LLDB DAP does not use the protocol-owned ASLR setting'
need "$POSIX" 'lldb_local_launch_probe "$reloc_c" C' 'POSIX LLDB process launch is not repeated after relocation'
reject "$POSIX" 'xcrun --find debugserver' 'macOS LLDB still uses a non-equivalent debugserver lookup proxy'
need "$WINDOWS" 'platform select remote-windows' 'Windows LLDB does not select remote-windows'
need "$WINDOWS" "'thread backtrace'" 'Windows LLDB does not use canonical thread backtrace'
reject "$WINDOWS" "'-o', 'backtrace'" 'Windows LLDB still contains invalid bare backtrace'
need "$WINDOWS" 'function Invoke-LldbDapProbe' 'Windows LLDB DAP claim has no protocol oracle'
need "$WINDOWS" 'disableASLR=$false' 'Windows LLDB DAP does not explicitly preserve normal ASLR'
need "$BUILD" 'requires.system_debugserver=true' 'macOS LLDB system-debugserver prerequisite is not explicit'
need "$BUILD" 'info_required_entry entry.lldb_dap' 'deliberate LLDB DAP command is not a required public entry'
need "$BUILD" 'info_required_entry entry.lldb_server' 'Linux/Windows deliberate LLDB server command is not a required public entry'
need "$BUILD" 'contents.lldb_server=$has_lldb_server' 'LLDB server payload inventory is not recorded independently from capability/entry scope'
reject "$BUILD" 'features.lldb_server=' 'LLDB still duplicates server presence as a behavioral capability'
need "$BUILD" 'lldb_process_launch="$has_lldb"' 'macOS LLDB local process launch is still incorrectly disabled'
need "$BUILD" 'lldb_dap_feature="$has_lldb_dap"' 'macOS LLDB DAP is still incorrectly disabled'
need "$BUILD" 'lldb_remote_debugging="$has_lldb_server"' 'Linux/Windows LLDB remote capability owner is missing'

# External platform requirements must be visible rather than hidden in runner behavior.
need "$REPORT_POSIX" "grep -E '^requires\\.'" 'POSIX capability reporter does not show external requirements'
need "$REPORT_WINDOWS" "-match '^requires\\.'" 'Windows capability reporter does not show external requirements'

[ "$failures" -eq 0 ] || exit 1
printf 'LLVM_CAPABILITY_SCOPE_POLICY=PASS\n'
