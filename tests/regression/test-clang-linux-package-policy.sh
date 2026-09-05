#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="${CUP_CLANG_BUILD_SCRIPT:-$REPO_ROOT/scripts/build/build-llvm-tool.sh}"
TEST_SCRIPT="${CUP_CLANG_TEST_SCRIPT:-$REPO_ROOT/scripts/test/test-llvm-tool.sh}"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
    echo "clang linux package policy test failed: $*" >&2
    exit 1
}

extract_function() {
    local file="$1"
    local function_name="$2"

    awk -v function_name="$function_name" '
        $0 ~ ("^" function_name "\\(\\) \\{") { in_function=1 }
        in_function { print }
        in_function && $0 == "}" { exit }
    ' "$file"
}

require_text() {
    local file="$1"
    local text="$2"

    grep -F -- "$text" "$file" >/dev/null ||
        fail "missing required text in ${file##*/}: $text"
}

test_linux_clang_cxx_config() {
    local source="$1"
    local tmp
    local package
    local function_file

    tmp="$TEST_TMP/config"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    package="$tmp/package root with spaces"
    function_file="$tmp/function.sh"

    extract_function "$source" write_linux_clang_cxx_driver_config >"$function_file"
    [ -s "$function_file" ] || fail "Linux Clang C++ config writer is absent"

    # shellcheck disable=SC1090
    source "$function_file"

    is_linux_platform() {
        case "$1" in linux-*) return 0 ;; *) return 1 ;; esac
    }
    log() { :; }

    PREFIX="$package"
    TOOL=clang
    HOST_PLATFORM=linux-x64
    write_linux_clang_cxx_driver_config

    [ -f "$package/bin/clang++.cfg" ] ||
        fail "Linux Clang C++ config was not generated"
    grep -Fx -- '-L<CFGDIR>/../lib' "$package/bin/clang++.cfg" >/dev/null ||
        fail "Linux Clang C++ config does not use CFGDIR-relative lib search"
    if grep -F -- "$package" "$package/bin/clang++.cfg" >/dev/null; then
        fail "Linux Clang C++ config embeds its installation prefix"
    fi
    if grep -Ev '^[[:space:]]*#' "$package/bin/clang++.cfg" |
        grep -F -- '-stdlib=libc++' >/dev/null; then
        fail "Linux Clang C++ config changed the default C++ runtime"
    fi

    rm -f "$package/bin/clang++.cfg"
    TOOL=lld
    write_linux_clang_cxx_driver_config
    [ ! -e "$package/bin/clang++.cfg" ] ||
        fail "Linux Clang C++ config writer affected LLD"

    TOOL=clang
    HOST_PLATFORM=windows-x64
    write_linux_clang_cxx_driver_config
    [ ! -e "$package/bin/clang++.cfg" ] ||
        fail "Linux Clang C++ config writer affected Windows"
}

test_resource_dir_containment() {
    local source="$1"
    local tmp
    local candidate
    local function_file
    local outside

    tmp="$TEST_TMP/resource"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    candidate="$tmp/package root with spaces"
    outside="$tmp/outside-resource"
    function_file="$tmp/function.sh"

    mkdir -p "$candidate/bin" "$candidate/lib/clang/22/include" "$outside/include"
    extract_function "$source" require_package_owned_clang_resource_dir >"$function_file"
    [ -s "$function_file" ] || fail "Clang resource containment helper is absent"

    # shellcheck disable=SC1090
    source "$function_file"

    cat >"$candidate/bin/clang" <<EOF
#!/usr/bin/env sh
if [ "\${1-}" = "-print-resource-dir" ]; then
    printf '%s\n' '$candidate/lib/clang/22'
    exit 0
fi
exit 2
EOF
    chmod 0755 "$candidate/bin/clang"

    resource_result="$(require_package_owned_clang_resource_dir "$candidate")"
    expected_resource="$(cd "$candidate/lib/clang/22" && pwd -P)"
    if [ "$resource_result" != "$expected_resource" ]; then
        fail "package-owned Clang resource dir was rejected"
    fi

    cat >"$candidate/bin/clang" <<EOF
#!/usr/bin/env sh
if [ "\${1-}" = "-print-resource-dir" ]; then
    printf '%s\n' '$outside'
    exit 0
fi
exit 2
EOF
    chmod 0755 "$candidate/bin/clang"

    if (require_package_owned_clang_resource_dir "$candidate" >/dev/null 2>&1); then
        fail "outside-package Clang resource dir was accepted"
    fi
}

test_static_contract() {
    require_text "$BUILD_SCRIPT" 'write_linux_clang_cxx_driver_config'
    require_text "$BUILD_SCRIPT" '-L<CFGDIR>/../lib'
    require_text "$BUILD_SCRIPT" 'write_windows_clang_driver_config'
    require_text "$BUILD_SCRIPT" 'write_linux_clang_cxx_driver_config'
    require_text "$BUILD_SCRIPT" 'elif is_linux_platform "$HOST_PLATFORM" && [ -f "$PREFIX/bin/clang++.cfg" ]; then'

    require_text "$TEST_SCRIPT" 'require_package_owned_clang_resource_dir'
    require_text "$TEST_SCRIPT" 'candidate_real="$(cd "$candidate" && pwd -P)"'
    require_text "$TEST_SCRIPT" 'resource_real="$(cd "$resource_dir" && pwd -P)"'
    require_text "$TEST_SCRIPT" 'unexpected host ld.lld fallback'
    require_text "$TEST_SCRIPT" 'env -i'
    require_text "$TEST_SCRIPT" '-flto -fuse-ld=lld'
    require_text "$TEST_SCRIPT" 'reloc_b="$tmp_root/relocated-clang-b"'
    require_text "$TEST_SCRIPT" 'reloc_c="$tmp_root/relocation c with spaces"'
    require_text "$TEST_SCRIPT" 'mv "$root" "$tmp_root/original-clang-root-disabled"'
    require_text "$TEST_SCRIPT" 'Clang relocation A root is still available'
    require_text "$TEST_SCRIPT" 'mv "$reloc_b" "$reloc_c"'
    require_text "$TEST_SCRIPT" 'Clang relocation B root is still available'

    # Preserve the deliberate public/integration model: clang and clang++ are
    # required entries; ld.lld may remain an optional Clang integration entry.
    require_text "$BUILD_SCRIPT" 'info_required_entry entry.clang "$PREFIX" clang'
    require_text "$BUILD_SCRIPT" 'info_required_entry entry.clang++ "$PREFIX" clang++'
    require_text "$BUILD_SCRIPT" 'info_entry_if_present entry.lld "$PREFIX" ld.lld'
    require_text "$BUILD_SCRIPT" 'contents.includes_lld=true'
    require_text "$BUILD_SCRIPT" 'features.cxx_runtime_default=false'
}

test_mutations() {
    local tmp
    local bad_build
    local bad_test

    tmp="$TEST_TMP/mutations"
    rm -rf "$tmp"
    mkdir -p "$tmp"

    bad_build="$tmp/build-llvm-tool.sh"
    cp "$BUILD_SCRIPT" "$bad_build"
    sed 's|-L<CFGDIR>/../lib|-L/host/lib|' "$bad_build" > "$bad_build.tmp"
    mv "$bad_build.tmp" "$bad_build"
    if (test_linux_clang_cxx_config "$bad_build" >/dev/null 2>&1); then
        fail "absolute Clang C++ library-search mutation was not detected"
    fi

    bad_test="$tmp/test-llvm-tool.sh"
    cp "$TEST_SCRIPT" "$bad_test"
    sed 's|resource_real="$(cd "$resource_dir" && pwd -P)"|resource_real="$candidate_real/lib/clang/22"|' "$bad_test" > "$bad_test.tmp"
    mv "$bad_test.tmp" "$bad_test"
    if (test_resource_dir_containment "$bad_test" >/dev/null 2>&1); then
        fail "resource-dir containment mutation was not detected"
    fi
}

test_static_contract
test_linux_clang_cxx_config "$BUILD_SCRIPT"
test_resource_dir_containment "$TEST_SCRIPT"
test_mutations

echo "CLANG_LINUX_PACKAGE_POLICY=PASS"
