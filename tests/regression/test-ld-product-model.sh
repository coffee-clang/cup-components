#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
BUILD="$ROOT/scripts/build/build-ld.sh"
COMMON="$ROOT/scripts/package/package-common.sh"
WORKFLOW="$ROOT/.github/workflows/build-ld.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

source "$COMMON"

[ "$(resolve_version ld stable)" = "$DEFAULT_BINUTILS_VERSION" ] || {
    echo 'GNU ld stable version does not inherit the configured Binutils source version' >&2
    exit 1
}
[ "$(package_component_for_tool ld)" = linker ] || {
    echo 'GNU ld is not mapped to the linker component' >&2
    exit 1
}
[ "$(package_version_name ld 1.0 linux-x64 linux-x64 "")" = 1.0 ] || {
    echo 'GNU ld package identity is not revisionless' >&2
    exit 1
}
[ "$(package_base_name ld 1.0 linux-x64 linux-x64 "")" = ld-1.0-linux-x64-linux-x64 ] || {
    echo 'GNU ld package basename does not match the product model' >&2
    exit 1
}
if (package_version_name ld 1.0 linux-x64 linux-x64 1) >/dev/null 2>&1; then
    echo 'GNU ld incorrectly accepted a GCC-style package revision' >&2
    exit 1
fi

for flag in --disable-werror --disable-nls --without-debuginfod --enable-ld --enable-plugins; do
    grep -F -- "$flag" "$BUILD" >/dev/null || {
        echo "GNU ld builder does not inherit Binutils flag: $flag" >&2
        exit 1
    }
done
grep -F 'prepare_source_tree binutils' "$BUILD" >/dev/null
grep -F 'contents.binutils_toolbox=false' "$BUILD" >/dev/null
grep -F 'contents.gcc_lto_plugin=false' "$BUILD" >/dev/null
grep -F 'info_required_entry entry.ld ' "$BUILD" >/dev/null
grep -F 'info_required_entry entry.target_ld ' "$BUILD" >/dev/null

if grep -F 'source "$REPO_ROOT/scripts/build/build-gcc.sh"' "$BUILD" >/dev/null 2>&1; then
    echo 'GNU ld builder incorrectly delegates product ownership to build-gcc.sh' >&2
    exit 1
fi

for tuple in \
    linux-x64:linux-x64 \
    linux-arm64:linux-arm64 \
    windows-x64:windows-x64 \
    linux-x64:windows-x64; do
    grep -F "$tuple" "$BUILD" >/dev/null || {
        echo "GNU ld builder is missing designed tuple: $tuple" >&2
        exit 1
    }
    grep -F "$tuple" "$WORKFLOW" >/dev/null || {
        echo "GNU ld workflow is missing designed tuple: $tuple" >&2
        exit 1
    }
done
if grep -Eq 'macos-x64|macos-arm64' "$WORKFLOW"; then
    echo 'GNU ld workflow advertises unsupported macOS tuples' >&2
    exit 1
fi
if grep -Eq '^[[:space:]]+revision:' "$WORKFLOW"; then
    echo 'GNU ld workflow incorrectly exposes a package revision input' >&2
    exit 1
fi

if CUP_WORK_DIR="$TMP/reject-work" CUP_OUT_DIR="$TMP/reject-dist" \
    "$BUILD" stable macos-x64 macos-x64 >"$TMP/macos.out" 2>&1; then
    echo 'GNU ld builder accepted an unsupported macOS tuple' >&2
    exit 1
fi
grep -F 'unsupported GNU ld build combination' "$TMP/macos.out" >/dev/null

# Exercise the shared finalizer with the GNU ld product identity without building Binutils.
export CUP_WORK_DIR="$TMP/package-work"
export CUP_OUT_DIR="$TMP/package-dist"
mkdir -p "$CUP_OUT_DIR"
prefix="$TMP/ld-fixture"
mkdir -p "$prefix/bin"
cat > "$prefix/bin/ld" <<'EOF_LD'
#!/usr/bin/env sh
printf 'GNU ld fixture\n'
EOF_LD
chmod 0755 "$prefix/bin/ld"
cat > "$prefix/info.txt" <<'EOF_INFO'
package.component=linker
package.tool=ld
package.version=1.0
package.mode=self-contained
package.formats=tar.xz,tar.gz,zip
platform.host=linux-x64
platform.target=linux-x64
platform.host_triple=x86_64-linux-gnu
platform.target_triple=x86_64-linux-gnu
platform.family=gnu
platform.runtime=glibc
platform.thread_model=posix
build.environment=test
build.source_policy=fixture
source.primary.name=binutils
source.primary.version=1.0
source.primary.url=https://example.invalid/binutils-1.0.tar.xz
source.primary.sha256=0000000000000000000000000000000000000000000000000000000000000000
entry.ld=bin/ld
contents.binutils_toolbox=false
contents.gcc_lto_plugin=false
features.link=true
features.link_elf=true
features.link_pe=false
config.plugins=true
EOF_INFO

create_packages ld 1.0 linux-x64 linux-x64 "" "$prefix"
base=ld-1.0-linux-x64-linux-x64
for format in tar.xz tar.gz zip; do
    [ -f "$CUP_OUT_DIR/$base.$format" ] || {
        echo "missing synthetic GNU ld package archive: $format" >&2
        exit 1
    }
done
grep -Fx "release_tag=$base" "$CUP_OUT_DIR/release.env" >/dev/null
verify_package_checksums "$base" "$CUP_OUT_DIR"
synthetic_root="$CUP_WORK_DIR/package-root/$base"
bash "$ROOT/scripts/test/package-capabilities.sh" "$synthetic_root" ld > "$TMP/ld-reporter.out"
grep -F '[GNU ld capability probes]' "$TMP/ld-reporter.out" >/dev/null
grep -F 'present  ld' "$TMP/ld-reporter.out" >/dev/null
if grep -F 'features.link=true  WARNING: declared true but executable missing' "$TMP/ld-reporter.out" >/dev/null; then
    echo 'GNU ld capability reporter emitted a false missing-linker warning' >&2
    exit 1
fi
grep -F "'ld' {" "$ROOT/scripts/test/package-capabilities-windows.ps1" >/dev/null
grep -F "Show-Executable 'ld.exe' 'features.link'" "$ROOT/scripts/test/package-capabilities-windows.ps1" >/dev/null

printf 'GNU_LD_PRODUCT_MODEL_STATIC_TEST=PASS\n'
