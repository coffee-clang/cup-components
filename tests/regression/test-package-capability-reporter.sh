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
    local driver_entry="${4:-true}"
    local binutils_entry="${5:-false}"

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
        printf 'entry.cpp=false\n'
        printf 'entry.gcov=false\n'
        printf 'contents.lto_dump=false\n'
        printf 'entry.target_gcc=%s\n' "$driver_entry"
        printf 'entry.target_ar=%s\n' "$binutils_entry"
    } > "$root/info.txt"
}

make_exe() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
    chmod 0755 "$path"
}

assert_no_declared_missing_warning() {
    local output="$1"
    if grep -Fq 'entry.target_gcc=true  WARNING: declared true but executable missing' "$output"; then
        echo "unexpected target-prefixed compiler-driver warning" >&2
        cat "$output" >&2
        return 1
    fi
}

assert_required_driver_warning() {
    local output="$1"
    grep -Fq 'declared:entry.target_gcc=true  WARNING: declared true but executable missing' "$output"
}

# GCC-specific canonical target overrides the generic package/platform triple.
fixture="$tmp/gcc-canonical"
make_fixture "$fixture" x86_64-linux-gnu x86_64-pc-linux-gnu true
make_exe "$fixture/bin/x86_64-pc-linux-gnu-gcc"
bash "$reporter" "$fixture" gcc > "$tmp/canonical.out"
grep -Fq '[target-prefixed compiler driver probes: x86_64-pc-linux-gnu]' "$tmp/canonical.out"
grep -Fq 'present  x86_64-pc-linux-gnu-gcc' "$tmp/canonical.out"
grep -Fq 'missing  x86_64-pc-linux-gnu-g++' "$tmp/canonical.out"
assert_no_declared_missing_warning "$tmp/canonical.out"

# The public entry means the canonical target-prefixed GCC driver itself must exist.
rm -f "$fixture/bin/x86_64-pc-linux-gnu-gcc"
bash "$reporter" "$fixture" gcc > "$tmp/missing-required.out"
assert_required_driver_warning "$tmp/missing-required.out"

# Without producer-specific GCC metadata, preserve the generic target-triple fallback.
fallback="$tmp/fallback"
make_fixture "$fallback" aarch64-linux-gnu "" true
make_exe "$fallback/bin/aarch64-linux-gnu-gcc"
bash "$reporter" "$fallback" gcc > "$tmp/fallback.out"
grep -Fq '[target-prefixed compiler driver probes: aarch64-linux-gnu]' "$tmp/fallback.out"
grep -Fq 'present  aarch64-linux-gnu-gcc' "$tmp/fallback.out"
assert_no_declared_missing_warning "$tmp/fallback.out"

# A deliberately wrong GCC canonical triple must not be rescued by a generic-triple executable.
mutated="$tmp/mutated"
make_fixture "$mutated" x86_64-linux-gnu wrong-vendor-linux-gnu true
make_exe "$mutated/bin/x86_64-linux-gnu-gcc"
bash "$reporter" "$mutated" gcc > "$tmp/mutated.out"
grep -Fq '[target-prefixed compiler driver probes: wrong-vendor-linux-gnu]' "$tmp/mutated.out"
assert_required_driver_warning "$tmp/mutated.out"

# Same metadata contract applies to the target-prefixed Binutils family:
# the producer boolean is anchored by canonical target-prefixed ar, while
# sibling tools remain inventory.
binutils_fixture="$tmp/binutils-canonical"
make_fixture "$binutils_fixture" x86_64-linux-gnu x86_64-pc-linux-gnu false true
make_exe "$binutils_fixture/bin/x86_64-pc-linux-gnu-ar"
bash "$reporter" "$binutils_fixture" gcc > "$tmp/binutils-canonical.out"
grep -Fq 'present  x86_64-pc-linux-gnu-ar' "$tmp/binutils-canonical.out"
if grep -Fq 'entry.target_ar=true  WARNING: declared true but executable missing' "$tmp/binutils-canonical.out"; then
    echo "unexpected target-prefixed Binutils sibling warning" >&2
    cat "$tmp/binutils-canonical.out" >&2
    exit 1
fi
rm -f "$binutils_fixture/bin/x86_64-pc-linux-gnu-ar"
bash "$reporter" "$binutils_fixture" gcc > "$tmp/binutils-missing-required.out"
grep -Fq 'declared:entry.target_ar=true  WARNING: declared true but executable missing' "$tmp/binutils-missing-required.out"

# A cross package whose public tool naming is target-prefixed must not emit
# false missing warnings for unprefixed tools that are deliberately absent.
cross="$tmp/cross-target-prefixed"
make_fixture "$cross" x86_64-w64-mingw32 x86_64-w64-mingw32 true true
printf 'config.tool_naming=target-prefixed\n' >> "$cross/info.txt"
sed -i \
    -e 's/^features.c=false$/features.c=true/' \
    -e 's/^features.cpp=false$/features.cpp=true/' \
    -e 's/^entry.cpp=false$/entry.cpp=true/' \
    -e 's/^entry.gcov=false$/entry.gcov=true/' \
    -e 's/^contents.lto_dump=false$/contents.lto_dump=true/' \
    "$cross/info.txt"
for exe in gcc g++ cpp gcov lto-dump ar as ld ranlib strip objdump readelf; do
    make_exe "$cross/bin/x86_64-w64-mingw32-$exe"
done
bash "$reporter" "$cross" gcc > "$tmp/cross.out"
if grep -Fq 'WARNING:' "$tmp/cross.out"; then
    echo 'target-prefixed GCC package produced a false missing-tool warning' >&2
    cat "$tmp/cross.out" >&2
    exit 1
fi
if grep -Eq '^  missing  (gcc|g\+\+|cpp|gcov|lto-dump|as|ld|ar|ranlib|strip|objdump|readelf)[[:space:]]' "$tmp/cross.out"; then
    echo 'target-prefixed GCC package was probed for deliberately absent unprefixed tools' >&2
    cat "$tmp/cross.out" >&2
    exit 1
fi
grep -Fq 'present  x86_64-w64-mingw32-lto-dump' "$tmp/cross.out"



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

for old_key in features.debuginfod features.source_highlight; do
    ! grep -F "$old_key=" "$gdb_builder" >/dev/null || {
        echo "GDB still promotes optional integration inventory into feature metadata: $old_key" >&2
        exit 1
    }
done
for key in config.debuginfod config.source_highlight contents.uses_debuginfod contents.uses_source_highlight; do
    grep -F "$key=" "$gdb_builder" >/dev/null || {
        echo "GDB metadata lost optional integration ownership: $key" >&2
        exit 1
    }
done

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
