#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
BUILD="$ROOT/scripts/build/build-ld.sh"
source "$ROOT/scripts/package/package-common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_fake_source() {
    local version="$1"
    local source_root="$TMP/source/binutils-$version"
    local archive="$TMP/binutils-$version.tar.xz"

    rm -rf "$TMP/source"
    mkdir -p "$source_root"

    cat > "$source_root/configure" <<'EOF_CONFIGURE'
#!/usr/bin/env sh
set -eu

prefix=
target=
for arg in "$@"; do
    case "$arg" in
        --prefix=*) prefix=${arg#--prefix=} ;;
        --target=*) target=${arg#--target=} ;;
    esac
done
[ -n "$prefix" ] || { echo 'fake configure missing --prefix' >&2; exit 1; }

cat > install.sh <<EOF_INSTALL
#!/usr/bin/env sh
set -eu
prefix='$prefix'
target='$target'
mkdir -p "\$prefix/bin"
if [ -n "\$target" ]; then
    name="\$target-ld"
else
    name=ld
fi
cat > "\$prefix/bin/\$name" <<'EOF_LD'
#!/usr/bin/env sh
if [ "\${1:-}" = --version ]; then
    printf 'GNU ld synthetic fixture\n'
fi
exit 0
EOF_LD
chmod 0755 "\$prefix/bin/\$name"
cp -p "\$prefix/bin/\$name" "\$prefix/bin/\$name.bfd"
printf '#!/usr/bin/env sh\nexit 0\n' > "\$prefix/bin/as"
printf '#!/usr/bin/env sh\nexit 0\n' > "\$prefix/bin/ar"
chmod 0755 "\$prefix/bin/as" "\$prefix/bin/ar"
EOF_INSTALL
chmod 0755 install.sh

cat > Makefile <<'EOF_MAKE'
all-ld:
	@:
install-ld:
	./install.sh
EOF_MAKE
EOF_CONFIGURE
    chmod 0755 "$source_root/configure"

    tar -C "$TMP/source" -cJf "$archive" "binutils-$version"
    printf '%s\n' "$archive"
}

run_case() {
    local version="$1"
    local host="$2"
    local target="$3"
    local case_root="$TMP/$host-$target"
    local work="$case_root/work"
    local out="$case_root/dist"
    local archive
    local sha
    local package_base="ld-$version-$host-$target"
    local extracted="$case_root/extracted/$package_base"
    local target_triple=x86_64-w64-mingw32

    archive="$(make_fake_source "$version")"
    sha="$(sha256_file "$archive")"
    mkdir -p "$work/src" "$out" "$case_root/extracted"
    cp "$archive" "$work/src/binutils-$version.tar.xz"

    CUP_WORK_DIR="$work" \
    CUP_OUT_DIR="$out" \
    CUP_SOURCE_SHA256="$sha" \
    CUP_BUILD_ENVIRONMENT=synthetic-static-test \
        "$BUILD" "$version" "$host" "$target"

    [ -f "$out/$package_base.tar.xz" ]
    [ -f "$out/$package_base.tar.gz" ]
    [ -f "$out/$package_base.zip" ]
    grep -Fx "release_tag=$package_base" "$out/release.env" >/dev/null
    tar -xJf "$out/$package_base.tar.xz" -C "$case_root/extracted"

    [ -x "$extracted/bin/ld" ]
    [ ! -e "$extracted/bin/as" ]
    [ ! -e "$extracted/bin/ar" ]
    grep -Fx 'package.component=linker' "$extracted/info.txt" >/dev/null
    grep -Fx 'package.tool=ld' "$extracted/info.txt" >/dev/null
    grep -Fx "package.version=$version" "$extracted/info.txt" >/dev/null
    grep -Fx 'source.primary.name=binutils' "$extracted/info.txt" >/dev/null
    grep -Fx "source.primary.sha256=$sha" "$extracted/info.txt" >/dev/null
    grep -Fx 'contents.binutils_toolbox=false' "$extracted/info.txt" >/dev/null
    grep -Fx 'contents.gcc_lto_plugin=false' "$extracted/info.txt" >/dev/null
    if grep -q '^package.revision=' "$extracted/info.txt"; then
        echo "synthetic GNU ld package unexpectedly declares package.revision: $host -> $target" >&2
        exit 1
    fi

    if [ "$host" = "$target" ]; then
        if grep -q '^entry.target_ld=' "$extracted/info.txt"; then
            echo 'native synthetic GNU ld package declared a cross target entry' >&2
            exit 1
        fi
    else
        grep -Fx "entry.target_ld=bin/$target_triple-ld" "$extracted/info.txt" >/dev/null
        [ -L "$extracted/bin/$target_triple-ld" ]
        [ "$(readlink "$extracted/bin/$target_triple-ld")" = ld ]
    fi

    grep -Fx 'entry.ld=bin/ld' "$extracted/info.txt" >/dev/null
    grep -Fx 'entry.ld_bfd=bin/ld.bfd' "$extracted/info.txt" >/dev/null
    [ -L "$extracted/bin/ld.bfd" ]
    [ "$(readlink "$extracted/bin/ld.bfd")" = ld ]
}

run_case 99.0 linux-x64 linux-x64
run_case 99.1 linux-x64 windows-x64

printf 'GNU_LD_BUILDER_SYNTHETIC_TEST=PASS\n'
