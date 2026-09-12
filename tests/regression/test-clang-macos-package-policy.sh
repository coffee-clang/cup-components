#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="${CUP_CLANG_BUILD_SCRIPT:-$REPO_ROOT/scripts/build/build-llvm-tool.sh}"
TEST_SCRIPT="${CUP_CLANG_TEST_SCRIPT:-$REPO_ROOT/scripts/test/test-llvm-tool.sh}"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
    echo "clang macOS package policy test failed: $*" >&2
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


mutate_sed() {
    local file="$1"
    local expression="$2"
    local tmp="$file.tmp"

    sed "$expression" "$file" > "$tmp" || fail "sed mutation failed: $expression"
    mv "$tmp" "$file"
}

has_doubled_line_continuation() {
    local file="$1"

    grep -nF ' \\' "$file" >/dev/null
}

assert_no_doubled_line_continuations() {
    local file="$1"

    if has_doubled_line_continuation "$file"; then
        fail "doubled shell line continuation found in ${file##*/}"
    fi
}

mutate_double_first_macos_continuation() {
    local file="$1"
    local tmp="$file.tmp"

    awk '
        !done && /TZ=UTC \\$/ { print $0 "\\"; done=1; next }
        { print }
        END { if (!done) exit 3 }
    ' "$file" > "$tmp" || fail 'unable to create doubled-line-continuation mutant'
    mv "$tmp" "$file"
}

write_function_fixture() {
    local target="$1"

    : > "$target"
    for fn in \
        require_executable \
        require_package_owned_clang_resource_dir \
        macos_macho_min_version \
        macos_version_at_most \
        macos_version_is \
        macos_test_is_runtime_macho \
        assert_macos_clang_package_contract; do
        extract_function "$TEST_SCRIPT" "$fn" >> "$target"
        printf '\n' >> "$target"
    done
}

make_fake_macos_tools() {
    local bin="$1"
    mkdir -p "$bin"

    cat > "$bin/file" <<'SH'
#!/usr/bin/env sh
case "$2" in
    */clang|*/ld64.lld|*/libfixture.dylib|*/libfixture.a) printf '%s\n' 'Mach-O 64-bit executable' ;;
    *) printf '%s\n' 'ASCII text' ;;
esac
SH

    cat > "$bin/lipo" <<'SH'
#!/usr/bin/env sh
[ "$1" = '-archs' ] || exit 2
case "$2" in
    *.a) printf '%s\n' "${MOCK_ARCHIVE_ARCH:-${MOCK_ARCH:-x86_64}}" ;;
    *) printf '%s\n' "${MOCK_ARCH:-x86_64}" ;;
esac
SH

    cat > "$bin/otool" <<'SH'
#!/usr/bin/env sh
[ "$1" = '-l' ] || exit 2
path="$2"
case "$path" in
    */clang|*/ld64.lld) minos="${MOCK_PRIMARY_MINOS:-15.0}" ;;
    *) minos="${MOCK_DEP_MINOS:-14.0}" ;;
esac
cat <<OUT
Load command 1
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos $minos
      sdk 15.0
OUT
SH

    cat > "$bin/codesign" <<'SH'
#!/usr/bin/env sh
if [ "${MOCK_CODESIGN_FAIL:-0}" = 1 ]; then
    exit 1
fi
exit 0
SH

    chmod +x "$bin/file" "$bin/lipo" "$bin/otool" "$bin/codesign"
}

make_candidate() {
    local root="$1"
    mkdir -p "$root/bin" "$root/lib"
    printf '#!/bin/sh\nexit 0\n' > "$root/bin/clang"
    printf '#!/bin/sh\nexit 0\n' > "$root/bin/ld64.lld"
    printf 'fixture\n' > "$root/lib/libfixture.dylib"
    printf '!<arch>\nfixture\n' > "$root/lib/libfixture.a"
    chmod +x "$root/bin/clang" "$root/bin/ld64.lld"
}

test_version_helpers() {
    local funcs="$TEST_TMP/version-functions.sh"
    : > "$funcs"
    for fn in macos_macho_min_version macos_version_at_most macos_version_is; do
        extract_function "$TEST_SCRIPT" "$fn" >> "$funcs"
        printf '\n' >> "$funcs"
    done
    # shellcheck disable=SC1090
    source "$funcs"

    otool() {
        cat <<'OUT'
Load command 1
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 15.0
      sdk 15.1
OUT
    }
    [ "$(macos_macho_min_version /fixture)" = 15.0 ] || fail 'LC_BUILD_VERSION minos parsing failed'

    otool() {
        cat <<'OUT'
Load command 1
      cmd LC_VERSION_MIN_MACOSX
  cmdsize 16
  version 14.4
      sdk 15.0
OUT
    }
    [ "$(macos_macho_min_version /fixture)" = 14.4 ] || fail 'LC_VERSION_MIN_MACOSX parsing failed'

    macos_version_at_most 14.6 15.0 || fail 'lower macOS floor rejected'
    macos_version_at_most 15.0 15.0 || fail 'equal macOS floor rejected'
    if macos_version_at_most 15.1 15.0; then
        fail 'higher macOS floor accepted'
    fi
    macos_version_is 15.0.0 15.0 || fail 'equivalent macOS version rejected'
    if macos_version_is 14.0 15.0; then
        fail 'non-equal macOS version accepted'
    fi

    unset -f otool
}

test_resource_dir_portability() {
    local candidate="$TEST_TMP/resource package with spaces"
    local outside="$TEST_TMP/outside-resource"
    local funcs="$TEST_TMP/resource-functions.sh"
    local result

    mkdir -p "$candidate/bin" "$candidate/lib/clang/22/include" "$outside/include"
    extract_function "$TEST_SCRIPT" require_package_owned_clang_resource_dir > "$funcs"
    [ -s "$funcs" ] || fail 'Clang resource containment helper is absent'

    # shellcheck disable=SC1090
    source "$funcs"

    cat > "$candidate/bin/clang" <<EOF
#!/usr/bin/env sh
if [ "\${1-}" = "-print-resource-dir" ]; then
    printf '%s\n' '$candidate/lib/clang/22'
    exit 0
fi
exit 2
EOF
    chmod +x "$candidate/bin/clang"

    result="$(require_package_owned_clang_resource_dir "$candidate")"
    [ "$result" = "$(cd "$candidate/lib/clang/22" && pwd -P)" ] ||
        fail 'portable package-owned Clang resource dir was rejected'

    cat > "$candidate/bin/clang" <<EOF
#!/usr/bin/env sh
if [ "\${1-}" = "-print-resource-dir" ]; then
    printf '%s\n' '$outside'
    exit 0
fi
exit 2
EOF
    chmod +x "$candidate/bin/clang"

    if (require_package_owned_clang_resource_dir "$candidate" >/dev/null 2>&1); then
        fail 'outside-package Clang resource dir was accepted'
    fi
}

test_package_contract_helper() {
    local funcs="$TEST_TMP/package-functions.sh"
    local fake_bin="$TEST_TMP/fake-macos-tools"
    local candidate="$TEST_TMP/package root with spaces"

    write_function_fixture "$funcs"
    make_fake_macos_tools "$fake_bin"
    make_candidate "$candidate"

    # shellcheck disable=SC1090
    source "$funcs"

    PATH="$fake_bin:$PATH" \
        MOCK_ARCH=x86_64 MOCK_PRIMARY_MINOS=15.0 MOCK_DEP_MINOS=14.0 \
        assert_macos_clang_package_contract "$candidate" x86_64 >/dev/null

    PATH="$fake_bin:$PATH" \
        MOCK_ARCH='x86_64 x86_64h' MOCK_PRIMARY_MINOS=15.0 MOCK_DEP_MINOS=14.0 \
        assert_macos_clang_package_contract "$candidate" x86_64 >/dev/null

    if (PATH="$fake_bin:$PATH" \
        MOCK_ARCH=x86_64h MOCK_PRIMARY_MINOS=15.0 MOCK_DEP_MINOS=14.0 \
        assert_macos_clang_package_contract "$candidate" x86_64 >/dev/null 2>&1); then
        fail 'x86_64h-only Mach-O package was accepted without the required x86_64 slice'
    fi

    if (PATH="$fake_bin:$PATH" \
        MOCK_ARCH=arm64 MOCK_PRIMARY_MINOS=15.0 MOCK_DEP_MINOS=14.0 \
        assert_macos_clang_package_contract "$candidate" x86_64 >/dev/null 2>&1); then
        fail 'wrong Mach-O architecture was accepted'
    fi

    if (PATH="$fake_bin:$PATH" \
        MOCK_ARCH=x86_64 MOCK_PRIMARY_MINOS=15.0 MOCK_DEP_MINOS=15.1 \
        assert_macos_clang_package_contract "$candidate" x86_64 >/dev/null 2>&1); then
        fail 'dependency floor above macOS 15.0 was accepted'
    fi

    if (PATH="$fake_bin:$PATH" \
        MOCK_ARCH=x86_64 MOCK_PRIMARY_MINOS=14.0 MOCK_DEP_MINOS=14.0 \
        assert_macos_clang_package_contract "$candidate" x86_64 >/dev/null 2>&1); then
        fail 'primary Clang minos different from 15.0 was accepted'
    fi

    if (PATH="$fake_bin:$PATH" \
        MOCK_ARCH=x86_64 MOCK_PRIMARY_MINOS=15.0 MOCK_DEP_MINOS=14.0 MOCK_CODESIGN_FAIL=1 \
        assert_macos_clang_package_contract "$candidate" x86_64 >/dev/null 2>&1); then
        fail 'invalid Mach-O signature was accepted'
    fi
}

test_static_relocation_contract() {
    assert_no_doubled_line_continuations "$TEST_SCRIPT"
    require_text "$TEST_SCRIPT" 'clang_macos_relocation_probe'
    require_text "$TEST_SCRIPT" 'candidate_real="$(cd "$candidate" && pwd -P)"'
    require_text "$TEST_SCRIPT" 'resource_real="$(cd "$resource_dir" && pwd -P)"'
    if grep -F 'realpath -e' "$TEST_SCRIPT" >/dev/null; then
        fail 'GNU-only realpath -e remains in shared Clang test path'
    fi
    require_text "$TEST_SCRIPT" 'assert_macos_clang_package_contract "$root" "$expected_arch"'
    require_text "$TEST_SCRIPT" 'reloc_b="$tmp_root/relocated-clang-macos-b"'
    require_text "$TEST_SCRIPT" 'reloc_c="$tmp_root/relocation clang macos c with real spaces"'
    require_text "$TEST_SCRIPT" 'mv "$root" "$tmp_root/original-clang-macos-root-disabled"'
    require_text "$TEST_SCRIPT" 'Clang macOS relocation A root is still available'
    require_text "$TEST_SCRIPT" 'mv "$reloc_b" "$reloc_c"'
    require_text "$TEST_SCRIPT" 'Clang macOS relocation B root is still available'
    require_text "$TEST_SCRIPT" 'clang_macos_relocation_probe "$reloc_b" B'
    require_text "$TEST_SCRIPT" 'clang_macos_relocation_probe "$reloc_c" C'
    require_text "$TEST_SCRIPT" 'CLANG_MACOS_RELOCATION_A_TO_B_TO_C=PASS'
    require_text "$TEST_SCRIPT" 'CLANG_MACOS_REAL_SPACES=PASS'
    require_text "$BUILD_SCRIPT" '-DLIBCXX_HERMETIC_STATIC_LIBRARY=ON'
    require_text "$BUILD_SCRIPT" '-DLIBCXXABI_HERMETIC_STATIC_LIBRARY=ON'
    require_text "$BUILD_SCRIPT" '-DLIBUNWIND_HIDE_SYMBOLS=ON'
    require_text "$BUILD_SCRIPT" '-DLIBCXX_INCLUDE_BENCHMARKS=OFF'
    require_text "$BUILD_SCRIPT" '-DLIBCXX_INSTALL_MODULES=OFF'
    require_text "$TEST_SCRIPT" '"$candidate/lib/libc++.a" "$candidate/lib/libunwind.a"'
    if grep -F '"$candidate/lib/libc++.a" "$candidate/lib/libc++abi.a" "$candidate/lib/libunwind.a"' "$TEST_SCRIPT" >/dev/null; then
        fail 'macOS libc++ probe redundantly links libc++abi although libc++.a owns the static ABI'
    fi
    require_text "$TEST_SCRIPT" 'MACOS_DEPENDENCY_FLOOR_NOT_ABOVE_15_0=PASS'
    require_text "$TEST_SCRIPT" 'MACOS_CODESIGN_VERIFY=PASS'
}


test_final_archive_architecture_policy() {
    local funcs="$TEST_TMP/final-architecture-functions.sh"
    local fake_bin="$TEST_TMP/final-architecture-tools"
    local candidate="$TEST_TMP/final-architecture-package"

    : > "$funcs"
    extract_function "$BUILD_SCRIPT" macos_native_arch >> "$funcs"
    printf '\n' >> "$funcs"
    extract_function "$BUILD_SCRIPT" verify_llvm_macos_architecture >> "$funcs"
    [ -s "$funcs" ] || fail 'final macOS architecture validator is absent'

    make_fake_macos_tools "$fake_bin"
    make_candidate "$candidate"

    # shellcheck disable=SC1090
    source "$funcs"
    is_macos_platform() { case "$1" in macos-*) return 0 ;; *) return 1 ;; esac; }
    die() { echo "$*" >&2; exit 1; }
    HOST_PLATFORM=macos-x64

    PATH="$fake_bin:$PATH" MOCK_ARCH=x86_64 MOCK_ARCHIVE_ARCH=x86_64 \
        verify_llvm_macos_architecture "$candidate" >/dev/null

    if (PATH="$fake_bin:$PATH" MOCK_ARCH=x86_64 MOCK_ARCHIVE_ARCH=i386 \
        verify_llvm_macos_architecture "$candidate" >/dev/null 2>&1); then
        fail 'wrong-architecture static archive was accepted by final macOS policy'
    fi
}

test_mutations() {
    local bad="$TEST_TMP/mutant.sh"

    cp "$TEST_SCRIPT" "$bad"
    mutate_double_first_macos_continuation "$bad"
    if (assert_no_doubled_line_continuations "$bad") >/dev/null 2>&1; then
        fail 'doubled-line-continuation mutant escaped'
    fi

    cp "$TEST_SCRIPT" "$bad"
    mutate_sed "$bad" 's/relocation clang macos c with real spaces/relocation-clang-macos-c/'
    if grep -F 'reloc_c="$tmp_root/relocation clang macos c with real spaces"' "$bad" >/dev/null; then
        fail 'real-space relocation mutant escaped'
    fi

    cp "$TEST_SCRIPT" "$bad"
    mutate_sed "$bad" '/mv "$root" "$tmp_root\/original-clang-macos-root-disabled"/d'
    if grep -F 'mv "$root" "$tmp_root/original-clang-macos-root-disabled"' "$bad" >/dev/null; then
        fail 'A-root isolation mutant escaped'
    fi

    cp "$TEST_SCRIPT" "$bad"
    mutate_sed "$bad" '/codesign --verify --strict/d'
    if grep -F 'codesign --verify --strict' "$bad" >/dev/null; then
        fail 'codesign verification mutant escaped'
    fi

    cp "$TEST_SCRIPT" "$bad"
    mutate_sed "$bad" 's|resource_real="$(cd "$resource_dir" && pwd -P)"|resource_real="$candidate_real/lib/clang/22"|'
    if (
        TEST_SCRIPT="$bad"
        test_resource_dir_portability
    ) >/dev/null 2>&1; then
        fail 'resource-dir containment mutant escaped'
    fi

    cp "$TEST_SCRIPT" "$bad"
    mutate_sed "$bad" 's/macos_version_at_most "$minos" 15.0/true/'
    if grep -F 'macos_version_at_most "$minos" 15.0' "$bad" >/dev/null; then
        fail 'dependency-floor mutant escaped'
    fi
}

test_static_relocation_contract
test_version_helpers
test_resource_dir_portability
test_package_contract_helper
test_final_archive_architecture_policy
test_mutations

echo 'CLANG_MACOS_PACKAGE_POLICY=PASS'
