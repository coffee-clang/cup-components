#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
reporter="$repo_root/scripts/test/package-capabilities.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_fixture() {
    local root="$1"
    local platform_triple="$2"
    local gcc_triple="${3:-}"
    local driver_entry="${4:-}"
    local binutils_entry="${5:-}"

    mkdir -p "$root/bin"
    {
        printf 'package.component=compiler\n'
        printf 'package.tool=gcc\n'
        printf 'package.version=1.0-rev1\n'
        printf 'platform.target_triple=%s\n' "$platform_triple"
        if [ -n "$gcc_triple" ]; then
            printf 'config.gcc_target_triple=%s\n' "$gcc_triple"
        fi
        printf 'features.c=false\n'
        printf 'features.cpp=false\n'
        printf 'contents.lto_dump=false\n'
        [ -z "$driver_entry" ] || printf 'entry.target_gcc=%s\n' "$driver_entry"
        [ -z "$binutils_entry" ] || printf 'entry.target_ar=%s\n' "$binutils_entry"
    } > "$root/info.txt"
}

make_exe() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'SCRIPT'
#!/usr/bin/env sh
exit 0
SCRIPT
    chmod 0755 "$path"
}

assert_no_warning() {
    local output="$1"
    if grep -Fq 'WARNING:' "$output"; then
        echo "unexpected capability-reporter warning" >&2
        cat "$output" >&2
        return 1
    fi
}

# GCC-specific canonical target overrides the generic package/platform triple,
# and entry.* is an exact package-relative path rather than a boolean flag.
fixture="$tmp/gcc-canonical"
make_fixture "$fixture" x86_64-linux-gnu x86_64-pc-linux-gnu \
    bin/x86_64-pc-linux-gnu-gcc
make_exe "$fixture/bin/x86_64-pc-linux-gnu-gcc"
bash "$reporter" "$fixture" gcc > "$tmp/canonical.out"
grep -Fq '[target-prefixed compiler driver probes: x86_64-pc-linux-gnu]' "$tmp/canonical.out"
grep -Fq 'present  x86_64-pc-linux-gnu-gcc' "$tmp/canonical.out"
grep -Fq 'declared:entry.target_gcc=bin/x86_64-pc-linux-gnu-gcc' "$tmp/canonical.out"
assert_no_warning "$tmp/canonical.out"

# A declared public entry whose executable is absent must be reported.
rm -f "$fixture/bin/x86_64-pc-linux-gnu-gcc"
bash "$reporter" "$fixture" gcc > "$tmp/missing-required.out"
grep -Fq 'declared:entry.target_gcc=bin/x86_64-pc-linux-gnu-gcc  WARNING: entry declared but executable missing' \
    "$tmp/missing-required.out"

# A path-valued entry must not be treated as truthy metadata: if the named
# executable exists but info.txt points the entry at another package path, the
# reporter must expose the semantic mismatch.
wrong_entry="$tmp/wrong-entry"
make_fixture "$wrong_entry" x86_64-linux-gnu x86_64-pc-linux-gnu bin/not-the-driver
make_exe "$wrong_entry/bin/x86_64-pc-linux-gnu-gcc"
bash "$reporter" "$wrong_entry" gcc > "$tmp/wrong-entry.out"
grep -Fq 'WARNING: entry path mismatch (actual:bin/x86_64-pc-linux-gnu-gcc)' "$tmp/wrong-entry.out"

# Without producer-specific GCC metadata, preserve the generic target-triple fallback.
fallback="$tmp/fallback"
make_fixture "$fallback" aarch64-linux-gnu "" bin/aarch64-linux-gnu-gcc
make_exe "$fallback/bin/aarch64-linux-gnu-gcc"
bash "$reporter" "$fallback" gcc > "$tmp/fallback.out"
grep -Fq '[target-prefixed compiler driver probes: aarch64-linux-gnu]' "$tmp/fallback.out"
grep -Fq 'present  aarch64-linux-gnu-gcc' "$tmp/fallback.out"
assert_no_warning "$tmp/fallback.out"

# A deliberately wrong GCC canonical triple must not be rescued by a generic-triple executable.
mutated="$tmp/mutated"
make_fixture "$mutated" x86_64-linux-gnu wrong-vendor-linux-gnu bin/wrong-vendor-linux-gnu-gcc
make_exe "$mutated/bin/x86_64-linux-gnu-gcc"
bash "$reporter" "$mutated" gcc > "$tmp/mutated.out"
grep -Fq '[target-prefixed compiler driver probes: wrong-vendor-linux-gnu]' "$tmp/mutated.out"
grep -Fq 'declared:entry.target_gcc=bin/wrong-vendor-linux-gnu-gcc  WARNING: entry declared but executable missing' \
    "$tmp/mutated.out"

# The same path-valued metadata contract applies to target-prefixed Binutils.
binutils_fixture="$tmp/binutils-canonical"
make_fixture "$binutils_fixture" x86_64-linux-gnu x86_64-pc-linux-gnu "" \
    bin/x86_64-pc-linux-gnu-ar
make_exe "$binutils_fixture/bin/x86_64-pc-linux-gnu-ar"
bash "$reporter" "$binutils_fixture" gcc > "$tmp/binutils-canonical.out"
grep -Fq 'present  x86_64-pc-linux-gnu-ar' "$tmp/binutils-canonical.out"
assert_no_warning "$tmp/binutils-canonical.out"
rm -f "$binutils_fixture/bin/x86_64-pc-linux-gnu-ar"
bash "$reporter" "$binutils_fixture" gcc > "$tmp/binutils-missing-required.out"
grep -Fq 'declared:entry.target_ar=bin/x86_64-pc-linux-gnu-ar  WARNING: entry declared but executable missing' \
    "$tmp/binutils-missing-required.out"

# A cross package whose public tool naming is target-prefixed must not probe
# deliberately absent unprefixed tools.
cross="$tmp/cross-target-prefixed"
make_fixture "$cross" x86_64-w64-mingw32 x86_64-w64-mingw32 \
    bin/x86_64-w64-mingw32-gcc bin/x86_64-w64-mingw32-ar
printf 'config.tool_naming=target-prefixed\n' >> "$cross/info.txt"
sed -i \
    -e 's/^features.c=false$/features.c=true/' \
    -e 's/^features.cpp=false$/features.cpp=true/' \
    -e 's/^contents.lto_dump=false$/contents.lto_dump=true/' \
    "$cross/info.txt"
for exe in gcc g++ cpp gcov lto-dump ar as ld ranlib strip objdump readelf; do
    make_exe "$cross/bin/x86_64-w64-mingw32-$exe"
done
bash "$reporter" "$cross" gcc > "$tmp/cross.out"
assert_no_warning "$tmp/cross.out"
if grep -Eq '^  missing  (gcc|g\+\+|cpp|gcov|lto-dump|as|ld|ar|ranlib|strip|objdump|readelf)[[:space:]]' "$tmp/cross.out"; then
    echo 'target-prefixed GCC package was probed for deliberately absent unprefixed tools' >&2
    cat "$tmp/cross.out" >&2
    exit 1
fi
grep -Fq 'present  x86_64-w64-mingw32-lto-dump' "$tmp/cross.out"

# Clang reporter follows the platform-native LLD frontend. A macOS package
# must report ld64.lld for features.lld_integration and must not diagnose the
# deliberately absent Linux frontend ld.lld.
clang_macos="$tmp/clang-macos"
mkdir -p "$clang_macos/bin"
cat > "$clang_macos/info.txt" <<'EOF_CLANG_MACOS_INFO'
package.component=compiler
package.tool=clang
package.version=1.0
platform.host=macos-x64
features.c=true
features.cpp=true
features.lld_integration=true
EOF_CLANG_MACOS_INFO
for exe in clang clang++ ld64.lld; do
    make_exe "$clang_macos/bin/$exe"
done
bash "$reporter" "$clang_macos" clang > "$tmp/clang-macos.out"
grep -Eq '^  present  ld64\.lld[[:space:]]+declared:features\.lld_integration=true' "$tmp/clang-macos.out"
! grep -Eq '^  (missing|present)[[:space:]]+ld\.lld[[:space:]]' "$tmp/clang-macos.out" || {
    echo 'macOS Clang reporter still probes the non-native ld.lld frontend' >&2
    cat "$tmp/clang-macos.out" >&2
    exit 1
}
assert_no_warning "$tmp/clang-macos.out"

# Metadata scope is repository-wide: executable/payload presence must not be
# promoted into behavioral features unless CUP deliberately qualifies it.
gcc_builder="$repo_root/scripts/build/build-gcc.sh"
ld_builder="$repo_root/scripts/build/build-ld.sh"
gdb_builder="$repo_root/scripts/build/build-gdb.sh"
valgrind_builder="$repo_root/scripts/build/build-valgrind.sh"

for old_key in \
    features.preprocessor features.gcov features.lto_dump features.plugin \
    features.binutils features.target_prefixed_compiler_drivers \
    features.target_prefixed_binutils features.target_layout_binutils \
    features.windows_target features.winpthreads; do
    ! grep -F "$old_key=" "$gcc_builder" >/dev/null || {
        echo "GCC still promotes inventory into feature metadata: $old_key" >&2
        exit 1
    }
done
for key in entry.cpp entry.gcov; do
    grep -F "$key" "$gcc_builder" >/dev/null || {
        echo "GCC metadata lost scoped public-entry ownership: $key" >&2
        exit 1
    }
done
for key in contents.lto_dump contents.lto_plugin contents.target_prefixed_compiler_drivers contents.target_prefixed_binutils contents.target_layout_binutils; do
    grep -F "$key=" "$gcc_builder" >/dev/null || {
        echo "GCC metadata lost scoped content ownership: $key" >&2
        exit 1
    }
done

for old_key in features.ld_bfd features.plugins features.target_prefixed; do
    ! grep -F "$old_key=" "$ld_builder" >/dev/null || {
        echo "GNU ld still promotes inventory/configuration into feature metadata: $old_key" >&2
        exit 1
    }
done
grep -F 'config.plugins=true' "$ld_builder" >/dev/null
grep -F 'info_entry_if_present entry.ld_bfd' "$ld_builder" >/dev/null
grep -F 'info_required_entry entry.target_ld' "$ld_builder" >/dev/null

for old_key in features.debuginfod features.source_highlight features.gdbserver; do
    ! grep -F "$old_key=" "$gdb_builder" >/dev/null || {
        echo "GDB still promotes inventory/integration state into feature metadata: $old_key" >&2
        exit 1
    }
done
for key in config.debuginfod config.source_highlight contents.uses_debuginfod contents.uses_source_highlight; do
    grep -F "$key=" "$gdb_builder" >/dev/null || {
        echo "GDB metadata lost optional integration ownership: $key" >&2
        exit 1
    }
done
grep -F 'info_required_entry entry.gdbserver' "$gdb_builder" >/dev/null || {
    echo 'GDB metadata lost gdbserver public-entry ownership' >&2
    exit 1
}
grep -F 'features.remote_debugging=$has_gdbserver' "$gdb_builder" >/dev/null || {
    echo 'GDB metadata lost remote-debugging behavioral ownership' >&2
    exit 1
}

for old_key in \
    features.cachegrind features.callgrind features.massif features.helgrind \
    features.drd features.dhat features.lackey features.exp_bbv \
    features.mpiwrap features.gdbserver features.gdb_python_frontend; do
    ! grep -F "$old_key=" "$valgrind_builder" >/dev/null || {
        echo "Valgrind still promotes retained runtime inventory into feature metadata: $old_key" >&2
        exit 1
    }
done
grep -F 'features.memcheck=$has_memcheck' "$valgrind_builder" >/dev/null
grep -F 'contents.tools=$tools_csv' "$valgrind_builder" >/dev/null
grep -F 'contents.vgdb=$has_vgdb' "$valgrind_builder" >/dev/null
grep -F 'config.gdbscripts_disabled=$VALGRIND_GDBSCRIPTS_DISABLED' "$valgrind_builder" >/dev/null

printf 'PACKAGE_METADATA_SCOPE_POLICY=PASS\n'
printf 'PACKAGE_CAPABILITY_REPORTER_TARGET_PREFIX_SEMANTICS=PASS\n'
