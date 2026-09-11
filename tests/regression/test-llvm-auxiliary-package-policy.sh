#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="$ROOT/scripts/build/build-llvm-tool.sh"
PACKAGE_COMMON="$ROOT/scripts/package/package-common.sh"
WINDOWS_TEST="$ROOT/scripts/test/test-llvm-tool-windows.ps1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "LLVM auxiliary package policy test failed: $*" >&2
    exit 1
}

extract_function() {
    local file="$1"
    local function_name="$2"

    awk -v function_name="$function_name" '
        $0 ~ ("^" function_name "\\(\\) \\{") { in_function=1; depth=0 }
        in_function {
            print
            line=$0
            opens=gsub(/\{/, "{", line)
            closes=gsub(/\}/, "}", line)
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$file"
}

make_exe() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    printf '#!/usr/bin/env sh\nexit 0\n' > "$path"
    chmod 0755 "$path"
}

make_payload_noise() {
    local prefix="$1"

    mkdir -p \
        "$prefix/include/clang-tidy" \
        "$prefix/share/clang" \
        "$prefix/share/clang-doc" \
        "$prefix/share/opt-viewer" \
        "$prefix/share/scan-build" \
        "$prefix/share/scan-view" \
        "$prefix/share/man/man1" \
        "$prefix/lib/libear" \
        "$prefix/lib/libscanbuild" \
        "$prefix/libexec"
    printf 'header\n' > "$prefix/include/clang-tidy/Check.h"
    printf 'share\n' > "$prefix/share/clang/sibling.py"
    printf 'doc\n' > "$prefix/share/clang-doc/index.js"
    printf 'opt\n' > "$prefix/share/opt-viewer/opt.py"
    printf 'scan\n' > "$prefix/share/scan-build/scan.py"
    printf 'view\n' > "$prefix/share/scan-view/view.py"
    printf 'man\n' > "$prefix/share/man/man1/scan-build.1"
    printf 'ear\n' > "$prefix/lib/libear/payload"
    printf 'scanlib\n' > "$prefix/lib/libscanbuild/payload"
    for helper in analyze-cc analyze-c++ intercept-cc intercept-c++ ccc-analyzer c++-analyzer; do
        make_exe "$prefix/libexec/$helper"
    done
    for lib in \
        libclang-cpp.23.1.dylib libclang-cpp.dylib \
        libRemarks.23.1.dylib libRemarks.dylib \
        libClangdXPCLib.23.1.dylib libClangdXPCLib.dylib; do
        printf 'dev-dylib\n' > "$prefix/lib/$lib"
    done
}

make_windows_analyzer_noise() {
    local prefix="$1"
    local helper
    local suffix

    mkdir -p "$prefix/libexec"
    for helper in analyze-cc analyze-c++ intercept-cc intercept-c++ ccc-analyzer c++-analyzer; do
        for suffix in .exe .bat .cmd; do
            make_exe "$prefix/libexec/$helper$suffix"
        done
    done
}

assert_noise_removed() {
    local prefix="$1"
    local path

    for path in \
        include/clang-tidy \
        share/clang share/clang-doc share/opt-viewer share/scan-build share/scan-view \
        share/man/man1/scan-build.1 \
        lib/libear lib/libscanbuild \
        libexec/analyze-cc libexec/analyze-c++ libexec/intercept-cc libexec/intercept-c++ \
        libexec/ccc-analyzer libexec/c++-analyzer \
        lib/libclang-cpp.23.1.dylib lib/libclang-cpp.dylib \
        lib/libRemarks.23.1.dylib lib/libRemarks.dylib \
        lib/libClangdXPCLib.23.1.dylib lib/libClangdXPCLib.dylib; do
        [ ! -e "$prefix/$path" ] && [ ! -L "$prefix/$path" ] ||
            fail "non-runtime payload survived pruning: $path"
    done
}

# The formatter helper policy must be explicit in build metadata too: an absent
# helper is not silently reintroduced by a later Python-packaging branch.
grep -F 'features.git_clang_format=false' "$BUILD_SCRIPT" >/dev/null ||
    fail 'clang-format metadata no longer records deliberate git-clang-format exclusion'
if grep -F 'clang-format) printf '''%s\n''' git-clang-format' "$BUILD_SCRIPT" >/dev/null; then
    fail 'git-clang-format re-entered the package-owned Python helper set'
fi
grep -F '[ "$TOOL" = clang-tidy ] || return 0' "$BUILD_SCRIPT" >/dev/null ||
    fail 'LLVM Python helper packaging is no longer bounded to clang-tidy'
grep -F "'-checks=-*,clang-analyzer-core.NullDereference', 'main[.]c$'" "$WINDOWS_TEST" >/dev/null ||
    fail 'Windows run-clang-tidy probe no longer uses a filesystem-independent file regex'
if grep -F "'-checks=-*,clang-analyzer-core.NullDereference', \$sourcePath" "$WINDOWS_TEST" >/dev/null; then
    fail 'Windows run-clang-tidy probe passes a filesystem path as a regular expression'
fi

# shellcheck source=/dev/null
source "$PACKAGE_COMMON"
functions="$TMP/build-functions.sh"
: > "$functions"
for fn in \
    is_kept_bin_tool \
    prune_bin_except \
    prune_llvm_package_bins \
    prune_llvm_auxiliary_share_payload \
    prune_llvm_development_payload \
    validate_llvm_package_layout; do
    extract_function "$BUILD_SCRIPT" "$fn" >> "$functions"
    printf '\n' >> "$functions"
done
# shellcheck source=/dev/null
source "$functions"

# clang-format is deliberately one public formatter command. Keeping
# git-clang-format would make a self-contained package depend on external Git
# and Python solely for an optional integration helper.
prefix="$TMP/clang-format"
mkdir -p "$prefix/bin" "$prefix/lib"
make_exe "$prefix/bin/clang-format"
make_exe "$prefix/bin/git-clang-format"
make_payload_noise "$prefix"
PREFIX="$prefix" TOOL=clang-format HOST_PLATFORM=linux-x64
prune_llvm_package_bins
prune_llvm_auxiliary_share_payload
prune_llvm_development_payload
validate_llvm_package_layout
[ -x "$prefix/bin/clang-format" ] || fail 'clang-format public root was removed'
[ ! -e "$prefix/bin/git-clang-format" ] || fail 'git-clang-format survived standalone formatter pruning'
[ ! -e "$prefix/libexec" ] || fail 'clang-format retained helper/analyzer libexec payload'
assert_noise_removed "$prefix"

# clang-tidy deliberately keeps its two Python helpers, but not the rest of the
# clang-tools-extra install surface.
prefix="$TMP/clang-tidy"
mkdir -p "$prefix/bin" "$prefix/libexec/llvm-python-scripts" "$prefix/lib"
for exe in clang-tidy clang-apply-replacements run-clang-tidy clang-tidy-diff; do make_exe "$prefix/bin/$exe"; done
make_exe "$prefix/libexec/python3"
printf 'print("run")\n' > "$prefix/libexec/llvm-python-scripts/run-clang-tidy.py"
printf 'print("diff")\n' > "$prefix/libexec/llvm-python-scripts/clang-tidy-diff.py"
make_payload_noise "$prefix"
PREFIX="$prefix" TOOL=clang-tidy HOST_PLATFORM=linux-x64
prune_llvm_package_bins
prune_llvm_auxiliary_share_payload
prune_llvm_development_payload
validate_llvm_package_layout
for exe in clang-tidy clang-apply-replacements run-clang-tidy clang-tidy-diff; do
    [ -x "$prefix/bin/$exe" ] || fail "clang-tidy deliberate root/helper was removed: $exe"
done
[ -x "$prefix/libexec/python3" ] || fail 'clang-tidy package-owned Python was removed'
[ -f "$prefix/libexec/llvm-python-scripts/run-clang-tidy.py" ] || fail 'run-clang-tidy implementation was removed'
[ -f "$prefix/libexec/llvm-python-scripts/clang-tidy-diff.py" ] || fail 'clang-tidy-diff implementation was removed'
assert_noise_removed "$prefix"

# clangd keeps its built-in Clang resource tree but not the XPC/development
# libraries installed by the broad clang-tools-extra target.
prefix="$TMP/clangd"
mkdir -p "$prefix/bin" "$prefix/lib/clang/23/include"
make_exe "$prefix/bin/clangd"
printf 'stddef\n' > "$prefix/lib/clang/23/include/stddef.h"
make_payload_noise "$prefix"
PREFIX="$prefix" TOOL=clangd HOST_PLATFORM=macos-x64
prune_llvm_package_bins
prune_llvm_auxiliary_share_payload
prune_llvm_development_payload
validate_llvm_package_layout
[ -f "$prefix/lib/clang/23/include/stddef.h" ] || fail 'clangd built-in resource header was removed'
assert_noise_removed "$prefix"


# LLD must not inherit LLVM's optimization-report Python utility or an empty
# include directory after its own headers are pruned.
prefix="$TMP/lld"
mkdir -p "$prefix/bin" "$prefix/include/lld" "$prefix/share/opt-viewer"
make_exe "$prefix/bin/lld"
printf 'header\n' > "$prefix/include/lld/Driver.h"
printf 'print("opt")\n' > "$prefix/share/opt-viewer/opt-viewer.py"
PREFIX="$prefix" TOOL=lld HOST_PLATFORM=linux-x64
prune_llvm_package_bins
prune_llvm_auxiliary_share_payload
prune_llvm_development_payload
[ -x "$prefix/bin/lld" ] || fail 'LLD public root was removed'
[ ! -e "$prefix/share/opt-viewer" ] || fail 'LLD retained unowned opt-viewer payload'
[ ! -e "$prefix/include" ] || fail 'LLD retained empty include directory'

# Windows command identity must use the common package candidate semantics:
# public .exe/.bat entries are accepted, while analyzer helpers are removed
# with all native suffixes rather than only their POSIX names.
prefix="$TMP/clangd-windows"
mkdir -p "$prefix/bin" "$prefix/lib/clang/23/include"
make_exe "$prefix/bin/clangd.exe"
printf 'stddef\n' > "$prefix/lib/clang/23/include/stddef.h"
make_windows_analyzer_noise "$prefix"
PREFIX="$prefix" TOOL=clangd HOST_PLATFORM=windows-x64
prune_llvm_package_bins
prune_llvm_auxiliary_share_payload
prune_llvm_development_payload
validate_llvm_package_layout
[ -e "$prefix/bin/clangd.exe" ] || fail 'Windows clangd .exe public root was removed'
[ ! -e "$prefix/libexec" ] || fail 'Windows clangd retained analyzer libexec variants'

prefix="$TMP/clang-tidy-windows"
mkdir -p "$prefix/bin" "$prefix/libexec/llvm-python-scripts" "$prefix/lib"
for exe in clang-tidy.exe clang-apply-replacements.exe; do make_exe "$prefix/bin/$exe"; done
make_exe "$prefix/bin/run-clang-tidy.bat"
make_exe "$prefix/bin/clang-tidy-diff.bat"
make_exe "$prefix/libexec/cup-python3.exe"
printf 'print("run")\n' > "$prefix/libexec/llvm-python-scripts/run-clang-tidy.py"
printf 'print("diff")\n' > "$prefix/libexec/llvm-python-scripts/clang-tidy-diff.py"
make_windows_analyzer_noise "$prefix"
PREFIX="$prefix" TOOL=clang-tidy HOST_PLATFORM=windows-x64
prune_llvm_package_bins
prune_llvm_auxiliary_share_payload
prune_llvm_development_payload
validate_llvm_package_layout
[ -e "$prefix/bin/run-clang-tidy.bat" ] || fail 'Windows run-clang-tidy wrapper was removed'
[ -e "$prefix/bin/clang-tidy-diff.bat" ] || fail 'Windows clang-tidy-diff wrapper was removed'

echo 'CLANG_FORMAT_EXTERNAL_GIT_HELPER_EXCLUSION=PASS'
echo 'CLANG_TIDY_SIBLING_PAYLOAD_PRUNING=PASS'
echo 'CLANGD_VERSIONED_DYLIB_AND_XPC_PRUNING=PASS'
echo 'LLD_AUXILIARY_PRUNING=PASS'
echo 'WINDOWS_LLVM_COMMAND_NAME_POLICY=PASS'

# Clang and LLDB inherit analyzer/editor share payload from the monorepo even
# though neither package exposes scan-build, scan-view or opt-viewer.
for tool in clang lldb; do
    prefix="$TMP/$tool-aux"
    rm -rf "$prefix"
    make_payload_noise "$prefix"
    mkdir -p "$prefix/share/libc++"
    printf 'keep\n' > "$prefix/share/libc++/module"
    PREFIX="$prefix" TOOL="$tool" prune_llvm_auxiliary_share_payload
    [ -f "$prefix/share/libc++/module" ] || fail "$tool pruning removed deliberate share/libc++ payload"
    for forbidden in share/clang share/clang-doc share/opt-viewer share/scan-build share/scan-view share/man/man1/scan-build.1; do
        [ ! -e "$prefix/$forbidden" ] || fail "$tool retained sibling auxiliary payload: $forbidden"
    done
done

# Windows embedding/development DLLs live in bin rather than lib. Runtime
# closure follows this pruning step and can restore only real import edges.
prefix="$TMP/windows-dev-dlls"
mkdir -p "$prefix/bin" "$prefix/lib"
for dll in libLTO.dll libRemarks.dll libclang.dll libclang-cpp.dll libClangdXPCLib.dll; do
    printf 'dev\n' > "$prefix/bin/$dll"
done
printf 'runtime\n' > "$prefix/bin/liblldb.dll"
PREFIX="$prefix" HOST_PLATFORM=windows-x64 TOOL=clangd prune_llvm_development_payload
for dll in libLTO.dll libRemarks.dll libclang.dll libclang-cpp.dll libClangdXPCLib.dll; do
    [ ! -e "$prefix/bin/$dll" ] || fail "Windows development DLL survived pruning: $dll"
done
[ -f "$prefix/bin/liblldb.dll" ] || fail 'unrelated runtime DLL was pruned'



# clang-format does not consume Clang compiler resource headers. Prove the
# common install-tree side effect is removed without affecting its executable.
prefix="$TMP/clang-format-resource-noise"
mkdir -p "$prefix/bin" "$prefix/lib/clang/23/include"
make_exe "$prefix/bin/clang-format"
printf 'stddef\n' > "$prefix/lib/clang/23/include/stddef.h"
PREFIX="$prefix" TOOL=clang-format HOST_PLATFORM=linux-x64
prune_llvm_development_payload
validate_llvm_package_layout "$prefix"
[ -x "$prefix/bin/clang-format" ] || fail 'clang-format executable was pruned'
[ ! -e "$prefix/lib/clang" ] || fail 'clang-format retained unused Clang resource headers'

make_lldb_resource_tree() {
    local prefix="$1"
    mkdir -p "$prefix/lib/clang/23/include"
    printf 'stddef\n' > "$prefix/lib/clang/23/include/stddef.h"
}

make_lldb_argdumper_companion() {
    local prefix="$1"
    local package_dir="$2"
    mkdir -p "$prefix/$package_dir/lldb"
    printf 'helper\n' > "$prefix/$package_dir/lldb/lldb-argdumper"
}

# LLDB packages exercise the same final pruning/validation policy on all native
# platform families. Linux/Windows retain the deliberate remote server; macOS
# instead keeps the private argdumper required by its normal `run` path.
prefix="$TMP/lldb-linux"
mkdir -p "$prefix/bin" "$prefix/lib"
for exe in lldb lldb-dap lldb-server lldb-argdumper; do make_exe "$prefix/bin/$exe"; done
make_lldb_resource_tree "$prefix"
make_lldb_argdumper_companion "$prefix" 'lib/python3.12/dist-packages'
make_payload_noise "$prefix"
PREFIX="$prefix" TOOL=lldb HOST_PLATFORM=linux-x64
prune_llvm_package_bins
prune_llvm_auxiliary_share_payload
prune_llvm_development_payload
validate_llvm_package_layout "$prefix"
for exe in lldb lldb-dap lldb-server; do
    [ -x "$prefix/bin/$exe" ] || fail "Linux LLDB deliberate root was removed: $exe"
done
[ ! -e "$prefix/bin/lldb-argdumper" ] || fail 'Linux LLDB retained lldb-argdumper'
[ ! -e "$prefix/lib/python3.12/dist-packages/lldb/lldb-argdumper" ] ||
    fail 'Linux LLDB retained Python-side lldb-argdumper companion'
assert_noise_removed "$prefix"

prefix="$TMP/lldb-macos"
mkdir -p "$prefix/bin" "$prefix/lib"
for exe in lldb lldb-dap lldb-server lldb-argdumper; do make_exe "$prefix/bin/$exe"; done
make_lldb_resource_tree "$prefix"
make_lldb_argdumper_companion "$prefix" 'lib/python3.12/site-packages'
make_payload_noise "$prefix"
PREFIX="$prefix" TOOL=lldb HOST_PLATFORM=macos-x64
prune_llvm_package_bins
prune_llvm_auxiliary_share_payload
prune_llvm_development_payload
validate_llvm_package_layout "$prefix"
for exe in lldb lldb-dap; do
    [ -x "$prefix/bin/$exe" ] || fail "macOS LLDB deliberate root was removed: $exe"
done
[ ! -e "$prefix/bin/lldb-server" ] || fail 'macOS LLDB retained out-of-scope lldb-server'
[ -x "$prefix/bin/lldb-argdumper" ] || fail 'macOS LLDB lost required private lldb-argdumper'
[ ! -e "$prefix/lib/python3.12/site-packages/lldb/lldb-argdumper" ] ||
    fail 'macOS LLDB retained Python-side lldb-argdumper companion'
assert_noise_removed "$prefix"

prefix="$TMP/lldb-windows"
mkdir -p "$prefix/bin" "$prefix/lib"
for exe in lldb.exe lldb-dap.exe lldb-server.exe lldb-argdumper.exe; do make_exe "$prefix/bin/$exe"; done
make_lldb_resource_tree "$prefix"
make_lldb_argdumper_companion "$prefix" 'lib/python3.12/site-packages'
make_payload_noise "$prefix"
make_windows_analyzer_noise "$prefix"
PREFIX="$prefix" TOOL=lldb HOST_PLATFORM=windows-x64
prune_llvm_package_bins
prune_llvm_auxiliary_share_payload
prune_llvm_development_payload
validate_llvm_package_layout "$prefix"
for exe in lldb.exe lldb-dap.exe lldb-server.exe; do
    [ -x "$prefix/bin/$exe" ] || fail "Windows LLDB deliberate root was removed: $exe"
done
[ ! -e "$prefix/bin/lldb-argdumper.exe" ] || fail 'Windows LLDB retained lldb-argdumper.exe'
[ ! -e "$prefix/lib/python3.12/site-packages/lldb/lldb-argdumper" ] ||
    fail 'Windows LLDB retained Python-side lldb-argdumper companion'
[ ! -e "$prefix/libexec" ] || fail 'Windows LLDB retained analyzer helper payload'

# Final validation must independently catch a forbidden helper reintroduced after
# pruning; otherwise a later package mutation could invalidate the earlier gate.
make_exe "$prefix/libexec/analyze-cc.exe"
if (validate_llvm_package_layout "$prefix") >/dev/null 2>&1; then
    fail 'LLDB final package validator accepted analyzer payload reintroduced after pruning'
fi
rm -f "$prefix/libexec/analyze-cc.exe"
rmdir "$prefix/libexec" 2>/dev/null || true
validate_llvm_package_layout "$prefix"

echo 'LLDB_FINAL_PACKAGE_SCOPE_POLICY=PASS'

echo 'LLVM_AUXILIARY_PACKAGE_POLICY=PASS'
