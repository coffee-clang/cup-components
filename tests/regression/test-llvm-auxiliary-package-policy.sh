#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="$ROOT/scripts/build/build-llvm-tool.sh"
PACKAGE_COMMON="$ROOT/scripts/package/package-common.sh"
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

echo 'CLANG_FORMAT_EXTERNAL_GIT_HELPER_EXCLUSION=PASS'
echo 'CLANG_TIDY_SIBLING_PAYLOAD_PRUNING=PASS'
echo 'CLANGD_VERSIONED_DYLIB_AND_XPC_PRUNING=PASS'
echo 'LLVM_AUXILIARY_PACKAGE_POLICY=PASS'
