#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="${CUP_CLANG_BUILD_SCRIPT:-$REPO_ROOT/scripts/build/build-llvm-tool.sh}"
PACKAGE_COMMON="${CUP_PACKAGE_COMMON_SCRIPT:-$REPO_ROOT/scripts/package/package-common.sh}"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
    echo "clang bin-pruning test failed: $*" >&2
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

write_regular_tool() {
    local path="$1"
    printf '#!/usr/bin/env sh\nexit 0\n' >"$path"
    chmod 0755 "$path"
}

assert_alias_resolves() {
    local prefix="$1"
    local alias="$2"
    local expected="$3"
    local resolved

    [ -L "$prefix/bin/$alias" ] || fail "retained alias is absent: $alias"
    resolved="$(package_resolve_staging_link "$prefix" "bin/$alias")" ||
        fail "retained alias does not resolve: $alias"
    [ "$resolved" = "bin/$expected" ] ||
        fail "retained alias resolves unexpectedly: $alias -> $resolved"
}

prepare_production_functions() {
    local functions="$TEST_TMP/build-functions.sh"

    : >"$functions"
    extract_function "$BUILD_SCRIPT" is_kept_bin_tool >>"$functions"
    extract_function "$BUILD_SCRIPT" prune_bin_except >>"$functions"
    extract_function "$BUILD_SCRIPT" prune_llvm_package_bins >>"$functions"

    grep -q '^is_kept_bin_tool()' "$functions" || fail "is_kept_bin_tool() extraction failed"
    grep -q '^prune_bin_except()' "$functions" || fail "prune_bin_except() extraction failed"
    grep -q '^prune_llvm_package_bins()' "$functions" || fail "prune_llvm_package_bins() extraction failed"

    # shellcheck disable=SC1090
    source "$functions"
}

prepare_clang_alias_graph() {
    local prefix="$1"
    local terminal="$2"
    local bin="$prefix/bin"

    mkdir -p "$bin"

    write_regular_tool "$bin/$terminal"
    write_regular_tool "$bin/lld"
    write_regular_tool "$bin/llvm-objcopy"
    write_regular_tool "$bin/llvm-ar"
    write_regular_tool "$bin/llvm-readobj"
    write_regular_tool "$bin/llvm-unrelated"
    write_regular_tool "$bin/llvm-unused-backing"

    ln -s "$terminal" "$bin/clang"
    ln -s clang "$bin/clang++"
    ln -s clang "$bin/clang-cl"
    ln -s clang "$bin/clang-cpp"

    ln -s lld "$bin/ld.lld"
    ln -s llvm-objcopy "$bin/llvm-strip"
    ln -s llvm-ar "$bin/llvm-ranlib"
    ln -s llvm-ar "$bin/llvm-lib"
    ln -s llvm-readobj "$bin/llvm-readelf"
    ln -s llvm-unused-backing "$bin/llvm-unused-alias"
}

assert_clang_alias_graph() {
    local prefix="$1"
    local terminal="$2"
    local bin="$prefix/bin"

    [ -f "$bin/$terminal" ] || fail "Clang pruning removed retained alias backing: $terminal"

    assert_alias_resolves "$prefix" clang "$terminal"
    assert_alias_resolves "$prefix" clang++ "$terminal"
    assert_alias_resolves "$prefix" clang-cl "$terminal"
    assert_alias_resolves "$prefix" clang-cpp "$terminal"

    assert_alias_resolves "$prefix" ld.lld lld
    assert_alias_resolves "$prefix" llvm-strip llvm-objcopy
    assert_alias_resolves "$prefix" llvm-ranlib llvm-ar
    assert_alias_resolves "$prefix" llvm-lib llvm-ar
    assert_alias_resolves "$prefix" llvm-readelf llvm-readobj

    [ ! -e "$bin/llvm-unrelated" ] && [ ! -L "$bin/llvm-unrelated" ] ||
        fail "Clang pruning retained unrelated LLVM executable"
    [ ! -e "$bin/llvm-unused-alias" ] && [ ! -L "$bin/llvm-unused-alias" ] ||
        fail "Clang pruning retained unrelated alias"
    [ ! -e "$bin/llvm-unused-backing" ] && [ ! -L "$bin/llvm-unused-backing" ] ||
        fail "Clang pruning retained backing of unrelated alias"

    (package_verify_staging_links "$prefix" linux-x64 >/dev/null 2>&1) ||
        fail "package symlink validation rejected the corrected Clang bin graph"
}

test_clang_pruning_alias_closure() {
    local prefix="$TEST_TMP/package root with spaces"

    prepare_clang_alias_graph "$prefix" clang-22

    PREFIX="$prefix"
    TOOL=clang
    HOST_PLATFORM=linux-x64

    prune_llvm_package_bins
    assert_clang_alias_graph "$prefix" clang-22

    echo "DRIVER_ALIAS_CLOSURE=PASS"
    echo "LLVM_ALIAS_CLOSURE=PASS"
    echo "UNRELATED_BIN_PRUNING=PASS"
    echo "COMMON_PACKAGE_LINK_VALIDATION=PASS"
}

test_dynamic_alias_backing() {
    local prefix="$TEST_TMP/anti-hardcode package"

    prepare_clang_alias_graph "$prefix" clang-fixture-terminal

    PREFIX="$prefix"
    TOOL=clang
    HOST_PLATFORM=linux-x64

    prune_llvm_package_bins
    assert_clang_alias_graph "$prefix" clang-fixture-terminal

    echo "ANTI_HARDCODE_ALIAS_BACKING_CONTROL=PASS"
}

# Load the actual common package-link validator, then the selected build script's
# actual pruning functions. The build script itself is not sourced because doing
# so would enter its production build main path.
# shellcheck disable=SC1090
source "$PACKAGE_COMMON"
prepare_production_functions

test_clang_pruning_alias_closure
test_dynamic_alias_backing

echo "CLANG_BIN_PRUNING=PASS"
