#!/usr/bin/env bash
set -euo pipefail
ROOT="${CUP_LLVM_CAPABILITY_POLICY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BUILD="$ROOT/scripts/build/build-llvm-tool.sh"
POSIX="$ROOT/scripts/test/test-llvm-tool.sh"
WINDOWS="$ROOT/scripts/test/test-llvm-tool-windows.ps1"
REPORT_POSIX="$ROOT/scripts/test/package-capabilities.sh"
REPORT_WINDOWS="$ROOT/scripts/test/package-capabilities-windows.ps1"
PACKAGE_COMMON="$ROOT/scripts/package/package-common.sh"
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
need "$BUILD" 'config.cxx_runtime_default=$cxx_runtime_default' 'C++ default policy is not recorded as configuration metadata'
reject "$BUILD" 'features.cxx_runtime_default=' 'C++ runtime default is still misclassified as a behavioral feature'
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
reject "$BUILD" 'features.sanitizers=' 'Clang still carries a redundant aggregate sanitizer feature'
need "$BUILD" '-DLLVM_ENABLE_LIBPFM=OFF' 'optional libpfm autodetection is not explicitly disabled'
need "$BUILD" '-DLLVM_INCLUDE_EXAMPLES=OFF' 'LLVM examples remain in the configure graph without a CUP consumer'
need "$BUILD" '-DLLVM_APPEND_VC_REV=OFF' 'LLVM binaries can still inherit false repository VCS provenance'
need "$BUILD" '-DLLVM_ENABLE_LIBEDIT=OFF' 'LLVM tool libedit autodetection is not disabled at its common owner'
need "$BUILD" '-DLIBCXX_HERMETIC_STATIC_LIBRARY=ON' 'macOS static libc++ is not hermetic'
need "$BUILD" '-DLIBCXXABI_HERMETIC_STATIC_LIBRARY=ON' 'macOS static libc++abi is not hermetic'
need "$BUILD" '-DLIBUNWIND_HIDE_SYMBOLS=ON' 'macOS static libunwind does not hide symbols'
need "$BUILD" '-DLIBCXX_INCLUDE_BENCHMARKS=OFF' 'libc++ benchmarks are still built without a CUP consumer'
need "$BUILD" '-DLIBCXX_INSTALL_MODULES=OFF' 'unowned libc++ module payload is still installed'
need "$BUILD" '-DLIBCXXABI_INSTALL_LIBRARY=OFF' 'standalone libc++abi archive is still installed despite static ABI ownership by libc++'
need "$BUILD" '-DCOMPILER_RT_BUILD_PROFILE_ROCM=OFF' 'ROCm profile runtime is not explicitly disabled'
need "$BUILD" '-DCOMPILER_RT_DEFAULT_TARGET_ONLY:BOOL=ON' 'compiler-rt target-only policy is not typed and explicit'
need "$BUILD" '-DCMAKE_OSX_ARCHITECTURES="$(macos_native_arch)"' 'macOS runtime sub-build is not constrained to the package architecture'
need "$BUILD" 'prune_unowned_clang_runtime_payload()' 'Clang runtime payload outside CUP scope has no producer-side prune owner'
for forbidden_runtime in profile_rocm ubsan_minimal ubsan_loop_detect c++experimental; do
    need "$BUILD" "*$forbidden_runtime*" "final Clang policy does not reject $forbidden_runtime payload"
done
need "$BUILD" 'package_verify_final_tool_policy()' 'LLVM exact-final-tree policy hook is missing'
need "$PACKAGE_COMMON" 'declare -F package_verify_final_tool_policy' 'common package finalizer does not invoke tool-specific final policy'
need "$BUILD" 'verify_llvm_final_architecture "$package_root"' 'final LLVM package architecture is not verified'

# Standalone LLD promises and ships only the native link frontend.
need "$BUILD" 'linux-*) prune_bin_except ld.lld' 'Linux LLD native frontend policy is missing'
need "$BUILD" 'windows-x64) prune_bin_except lld-link' 'Windows LLD native frontend policy is missing'
need "$BUILD" 'macos-*) prune_bin_except ld64.lld' 'macOS LLD native frontend policy is missing'
need "$BUILD" 'features.link_wasm=false' 'LLD incorrectly promotes WebAssembly linking into the current CUP target matrix'
reject "$BUILD" 'append_lld_frontend_info' 'forbidden LLD frontend inventory can still re-enter metadata'
need "$POSIX" 'lld_native_probe()' 'POSIX LLD has no native-format behavioral owner'
need "$WINDOWS" 'function Invoke-LldNativeProbe' 'Windows LLD has no native COFF behavioral owner'
need "$WINDOWS" "'/manifest:embed'" 'Windows LLD does not exercise COFF manifest handling'
need "$WINDOWS" "'architecture:\s*i386:x86-64'" 'Windows LLD does not verify AMD64 output architecture'
reject "$POSIX" 'lld_cross_format_probe()' 'cross-format LLD qualification is still present'
reject "$WINDOWS" 'Invoke-LldCrossFormatProbe' 'Windows cross-format LLD qualification is still present'
[ ! -e "$ROOT/tests/fixtures/lld" ] || { echo 'LLVM capability-scope policy: LLD cross-format fixture directory still exists' >&2; failures=$((failures + 1)); }

# clang-tidy helper capabilities remain deliberate and must be exercised behaviorally.
need "$POSIX" 'clang_tidy_replacements_probe()' 'clang-tidy has no replacement oracle'
need "$POSIX" '--export-fixes=' 'clang-tidy replacement oracle does not export real fixes'
need "$POSIX" 'clang_tidy_replacements_probe "$root" A' 'clang-apply-replacements is not exercised at original root'
need "$POSIX" 'clang_tidy_replacements_probe "$reloc_c" C' 'clang-apply-replacements is not exercised after relocation'
need "$WINDOWS" 'function Invoke-ClangTidyReplacementsProbe' 'Windows clang-tidy has no replacement oracle'
need "$BUILD" 'contents.clang_resources=true' 'clang-tidy Clang resource ownership is not recorded'
need "$BUILD" 'info_required_entry entry.clang_apply_replacements' 'clang-tidy apply-replacements entry is not fail-closed'
need "$BUILD" 'info_required_entry entry.run_clang_tidy' 'run-clang-tidy entry is not fail-closed'
need "$BUILD" 'info_required_entry entry.clang_tidy_diff' 'clang-tidy-diff entry is not fail-closed'

# clangd must be tested as a real language server without promoting background indexing to CUP scope.
reject "$BUILD" 'features.background_index=' 'clangd background indexing is still promoted to a CUP feature'
reject "$BUILD" 'features.indexer=' 'optional clangd-indexer payload is still promoted to a CUP feature'
reject "$BUILD" 'entry.clangd_indexer' 'optional clangd-indexer payload is still promoted to a public entry'
reject "$BUILD" 'contents.clangd_indexer=' 'clangd-indexer remains admitted as optional package inventory'
need "$POSIX" 'clangd_lsp_probe()' 'POSIX clangd has no real LSP oracle'
need "$POSIX" 'textDocument/documentSymbol' 'POSIX clangd LSP oracle does not issue a semantic document request'
need "$POSIX" 'clangd_lsp_probe "$root" A' 'clangd LSP oracle is not run at original root'
need "$POSIX" 'clangd_lsp_probe "$reloc_c" C' 'clangd LSP oracle is not repeated after relocation'
need "$WINDOWS" 'function Invoke-ClangdLspProbe' 'Windows clangd has no real LSP oracle'
need "$BUILD" 'features.lsp=true' 'clangd LSP behavior is not represented as a deliberate feature'
need "$POSIX" 'info_bool features.lsp' 'POSIX clangd can silently skip the declared LSP capability'
need "$WINDOWS" "'features.lsp'" 'Windows clangd can silently skip the declared LSP capability'
need "$WINDOWS" 'ConvertTo-Json -InputObject $db -Depth 10' 'Windows clangd compile_commands array can collapse to an object'
need "$WINDOWS" 'Failed to load compilation database|Failed to find compilation database|command clangd fallback' 'Windows clangd LSP does not reject compilation-database fallback'
need "$WINDOWS" '$process.StandardError.ReadToEndAsync()' 'Windows framed protocol stderr is not drained asynchronously'
need "$WINDOWS" '#include <stddef.h>' 'Windows clangd does not exercise packaged builtin headers'
need "$BUILD" '-DCLANGD_BUILD_DEXP=OFF' 'clangd index-development utility is still built'
need "$BUILD" '-DCLANGD_BUILD_XPC=OFF' 'clangd XPC transport is still built on Darwin'
need "$BUILD" '-DCLANGD_TIDY_CHECKS=OFF' 'clangd still embeds clang-tidy checks outside the current CUP clangd contract'
reject "$POSIX" '.cache/clangd/index' 'POSIX clangd still requires background-index cache internals'
reject "$WINDOWS" 'background-index entries' 'Windows clangd still requires background-index cache internals'

# LLDB retains deliberate process-control/DAP/remote responsibilities without
# promoting helper presence or non-equivalent platform probes into capabilities.
need "$POSIX" '"$candidate/bin/lldb-server" platform --server' 'Linux LLDB does not use packaged platform-server mode'
need "$POSIX" 'platform select remote-linux' 'Linux LLDB does not select remote-linux'
reject "$POSIX" 'gdb-remote 127.0.0.1:$port' 'obsolete direct targetless gdb-remote orchestration is still present'
need "$POSIX" 'lldb_dap_probe()' 'POSIX LLDB DAP claim has no protocol oracle'
need "$POSIX" 'local deadline=$((SECONDS + timeout_seconds))' 'POSIX framed waiter still lacks a real time deadline'
reject "$POSIX" 'max_reads' 'POSIX framed waiter still limits protocol progress by message count'
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
need "$BUILD" 'contents.lldb_argdumper=$has_lldb_argdumper' 'LLDB private argdumper inventory is not recorded'
need "$BUILD" 'prune_bin_except lldb lldb-dap lldb-argdumper' 'macOS LLDB does not retain the private argdumper required by normal run'
need "$POSIX" 'require_executable "$root/bin/lldb-argdumper"' 'macOS LLDB product test does not require its private argdumper'
reject "$BUILD" 'features.lldb_server=' 'LLDB still duplicates server presence as a behavioral capability'
need "$BUILD" 'features.process_launch=true' 'LLDB local process launch is not a deliberate capability'
need "$BUILD" 'features.lldb_dap=true' 'LLDB DAP is not a deliberate capability'
need "$BUILD" 'features.remote_debugging=$(is_macos_platform "$HOST_PLATFORM" && printf false || printf true)' 'LLDB remote-debugging platform policy is missing'

# External platform requirements and platform-owned SDK discovery must be explicit.
need "$BUILD" 'requires.system_development_environment=true' 'Linux Clang native development environment prerequisite is not explicit'
need "$BUILD" '-DCLANG_USE_XCSELECT=ON' 'macOS Clang does not consume the Apple SDK prerequisite through xcselect'

# External platform requirements must be visible rather than hidden in runner behavior.
need "$REPORT_POSIX" "grep -E '^requires\\.'" 'POSIX capability reporter does not show external requirements'
need "$REPORT_WINDOWS" "-match '^requires\\.'" 'Windows capability reporter does not show external requirements'

[ "$failures" -eq 0 ] || exit 1
printf 'LLVM_CAPABILITY_SCOPE_POLICY=PASS\n'
